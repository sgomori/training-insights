module Ai
  # Answers one visitor question.
  #
  # Each call is a turn on its own: no history is sent and none is kept. That is
  # what makes an answer cacheable on the question text alone, and it is the
  # tradeoff the caching buys — a follow-up cannot resolve against what came
  # before, so the prompt tells the model to say so.
  class Chat
    DEFAULT_MODEL = "claude-opus-5".freeze

    def self.call(...) = new(...).call

    def initialize(question:, runner_name: nil, client: Client.new)
      @question = question
      @runner_name = runner_name
      @client = client
    end

    def call
      @client.answer(
        system: ChatPrompt.for(@runner_name),
        question: @question,
        model: ENV.fetch("ANTHROPIC_CHAT_MODEL", DEFAULT_MODEL)
      )
    end
  end
end
