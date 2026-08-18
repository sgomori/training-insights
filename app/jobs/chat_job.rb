# Answers one visitor question and pushes the answer back to the page.
#
# Chat cannot run inline. A turn takes 15 to 30 seconds, and while it runs the
# model is calling back into this application's own tool endpoint several times
# — inbound requests that need request threads of their own. Holding one of a
# small pool of them open for the length of a turn would let a handful of
# concurrent visitors deadlock the site against itself. So the request enqueues
# and returns, and the answer arrives over the socket when it is ready.
class ChatJob < ApplicationJob
  # Its own queue, so a turn a visitor is waiting on does not sit behind a
  # content regeneration that nobody is.
  queue_as :chat

  # Fixed strings, both of them. A visitor is anonymous and the failure is not
  # theirs to debug; an exception message in a chat bubble is an information
  # leak. The real error goes to the log, which is where it is any use.
  REFUSED = "That one can't be answered here. Ask about the training and I'll have a go.".freeze
  FAILED = "Something went wrong working that out. The training data is fine — try again in a moment.".freeze

  def perform(question, turn_id)
    turn = ChatTurn.new(question: question, id: turn_id)

    answer = Ai::Chat.call(question: question, runner_name: Runner.current&.name)
    Answers::Cache.write_answer(question, answer)
    deliver(turn, answer)
  rescue Ai::Client::Refused => e
    Rails.logger.warn("Chat declined: #{e.message}")
    deliver(turn, REFUSED)
  rescue StandardError => e
    # Swallowed rather than re-raised: a retry would answer a visitor who has
    # already been told it failed, and would replace a bubble they may have
    # scrolled past. The log line is the signal that something needs looking at.
    Rails.logger.error("Chat failed: #{e.class}: #{e.message}")
    deliver(turn, FAILED)
  end

  private

  def deliver(turn, answer)
    Turbo::StreamsChannel.broadcast_replace_to(
      turn.stream_name,
      target: turn.dom_id,
      partial: "chats/answer",
      locals: { turn: turn, answer: answer }
    )
  end
end
