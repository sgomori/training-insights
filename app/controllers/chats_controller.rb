# The site's own chat, answering one question at a time.
#
# Nothing is answered inline. A turn takes 15 to 30 seconds and the model calls
# back into this application's tool endpoint several times while it runs, which
# needs request threads of its own — so a synchronous action would hold a thread
# open while competing with the callbacks it is waiting on. The request enqueues,
# renders a pending bubble, and the answer arrives over the socket.
#
# The exception is a question already answered against the current data, which
# comes straight back out of the cache with no job and no model call at all.
class ChatsController < ApplicationController
  MAX_LENGTH = 500

  TOO_LONG = "That question is longer than this can take. Try it in a sentence or two.".freeze

  def create
    question = params[:question].to_s.strip

    return head :no_content if question.blank?
    return respond_with(ChatTurn.new(question: question.truncate(MAX_LENGTH)), TOO_LONG) if question.length > MAX_LENGTH

    turn = ChatTurn.new(question: question)
    answered = Answers::Cache.answer_to(question)

    return respond_with(turn, answered) if answered

    ChatJob.perform_later(question, turn.id)
    respond_pending(turn)
  end

  private

  def respond_with(turn, answer)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          append(turn, "chats/question"),
          append(turn, "chats/answer", answer: answer)
        ]
      end
      format.html { redirect_to root_path }
    end
  end

  def respond_pending(turn)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          append(turn, "chats/question"),
          append(turn, "chats/pending")
        ]
      end
      format.html { redirect_to root_path }
    end
  end

  def append(turn, partial, **locals)
    turbo_stream.append("transcript", partial: partial, locals: { turn: turn, **locals })
  end
end
