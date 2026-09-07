module Ai
  # The one place this application talks to Anthropic.
  #
  # It attaches the MCP server as a tool source over the public URL, so the model
  # reaches the training history through exactly the same interface an external
  # client uses. There is no database handle on this side of the wire and no
  # shortcut for the model to find — only one we could build, which is why this
  # class and everything beside it touch no records.
  class Client
    Error = Class.new(StandardError)

    # The safety classifiers declined, or declined again after falling back.
    Refused = Class.new(Error)

    # A successful call that carried no prose. Rare, and indistinguishable from a
    # blank answer downstream unless it is raised here.
    Empty = Class.new(Error)

    # The model ran out of output tokens mid-answer. The prose it did write is a
    # sentence that stops rather than an answer, and returning it would let the
    # caller cache it as one.
    Truncated = Class.new(Error)

    # Caps thinking and response text together, so this is not the length of the
    # answer. Two or three paragraphs need a fraction of it; the rest is
    # headroom for the model to work through several tool calls without being
    # truncated mid-sentence. Under the SDK's ten-minute non-streaming ceiling.
    MAX_TOKENS = 16_384

    # Cost and latency are controlled here rather than by turning thinking off.
    # Disabling it lets the model write a tool call into its visible text instead
    # of emitting a tool-use block: the turn succeeds, the call never runs, and
    # nothing raises. A wrong answer that looks right is worse than a slow one.
    EFFORT = :low

    # A turn runs 15 to 30 seconds. The SDK retries a timeout, so the wall clock
    # is this times the attempts; 150 seconds is past the point the page has
    # given up on the bubble, and well short of the default ten minutes, which
    # would outlive the process shutdown window many times over.
    TIMEOUT_SECONDS = 75
    MAX_RETRIES = 1

    # A long tool-using turn can come back paused, with the work so far as its
    # content and a stop reason asking for it to be sent back and continued.
    # Bounded, because a turn that pauses this many times is not converging.
    MAX_CONTINUATIONS = 3

    BETAS = [ "mcp-client-2025-11-20", "server-side-fallback-2026-07-01" ].freeze

    # A client-side label only: it binds the declared server to the toolset that
    # references it. Both halves are required — a server with no toolset pointing
    # at it is rejected before the model sees the request.
    TOOL_SOURCE = "training-insights".freeze

    def initialize(client: nil)
      @client = client
    end

    # Returns the answer as prose. Raises rather than returning a blank string on
    # every failure, so a caller cannot mistake one for an answer.
    def answer(system:, question:, model:)
      params = request(system:, question:, model:)
      messages = [ client.beta.messages.create(**params) ]

      # The paused turn's content goes back as the assistant's own words, and the
      # conversation picks up where it stopped.
      while messages.last.stop_reason == :pause_turn && messages.size <= MAX_CONTINUATIONS
        params[:messages] += [ { role: :assistant, content: messages.last.content } ]
        messages << client.beta.messages.create(**params)
      end

      final = messages.last
      raise Refused, "declined with #{final.stop_details&.category || 'no category'}" if final.stop_reason == :refusal
      raise Truncated, "stopped at max_tokens (#{MAX_TOKENS}) before the answer was complete" if final.stop_reason == :max_tokens
      raise Truncated, "still paused after #{MAX_CONTINUATIONS} continuations" if final.stop_reason == :pause_turn

      # Prose from every segment, in order: a turn that paused may have written
      # part of the answer before it did.
      messages.map { |message| prose(message) }.reject(&:blank?).join("\n\n").presence or
        raise Empty, "no text blocks in a #{final.stop_reason} response"
    end

    private

    def client
      @client ||= build_client
    end

    def build_client
      Anthropic::Client.new(
        api_key: ENV.fetch("ANTHROPIC_API_KEY"),
        timeout: TIMEOUT_SECONDS,
        max_retries: MAX_RETRIES
      )
    end

    def request(system:, question:, model:)
      {
        model: model,
        max_tokens: MAX_TOKENS,
        system_: system,
        output_config: { effort: EFFORT },
        betas: BETAS,
        # Re-runs a declined request on a substitute model server-side. Without
        # it a refusal reaches the visitor as a dead turn.
        fallbacks: :default,
        mcp_servers: [ {
          type: :url,
          name: TOOL_SOURCE,
          url: ENV.fetch("MCP_SERVER_URL"),
          authorization_token: ENV.fetch("MCP_API_KEY")
        } ],
        tools: [ { type: :mcp_toolset, mcp_server_name: TOOL_SOURCE } ],
        messages: [ { role: :user, content: question } ]
      }
    end

    # Content blocks are polymorphic and their type is a Symbol. Filtering before
    # reading is what keeps a thinking or fallback block from raising here.
    def prose(message)
      message.content.filter_map { |block| block.text if block.type == :text }.join("\n\n").strip
    end
  end
end
