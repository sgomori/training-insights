module Ai
  # Writes the standing summary at the top of the site.
  #
  # It takes no training data. The activity that triggered a regeneration is a
  # signal that the history changed and a key to cache the result under — never
  # an input. Handing rows to the model here would be the easy thing to do and
  # would build the second path to the training data that routing chat through
  # the public tool interface exists to prevent.
  class Content
    DEFAULT_MODEL = "claude-opus-5".freeze

    def self.call(...) = new(...).call

    def initialize(runner_name: nil, client: Client.new)
      @runner_name = runner_name
      @client = client
    end

    def call
      @client.answer(
        system: ContentPrompt.for(@runner_name),
        question: ContentPrompt.request,
        model: ENV.fetch("ANTHROPIC_CONTENT_MODEL", DEFAULT_MODEL)
      )
    end
  end
end
