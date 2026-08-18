# One question and its answer on the page.
#
# Not a record. Turns are independent and the answers live in the cache, so
# there is nothing here worth persisting — this exists so the controller that
# opens a turn and the job that finishes it agree on what to call it, rather than
# building the same string from the same token in two places.
class ChatTurn
  attr_reader :id, :question

  def initialize(question:, id: nil)
    @question = question
    @id = id || SecureRandom.uuid
  end

  # The channel the pending bubble subscribes to. Scoped per turn, so a visitor
  # is never sent an answer to someone else's question.
  def stream_name
    "chat_turn:#{id}"
  end

  def dom_id
    "chat_turn_#{id}"
  end
end
