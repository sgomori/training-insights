require "rails_helper"

RSpec.describe Ai::Client do
  subject(:client) { described_class.new(client: anthropic) }

  let(:anthropic) { double(beta: double(messages: messages)) }
  let(:messages) { double }

  around do |example|
    with_env("MCP_SERVER_URL" => "https://example.test/mcp", "MCP_API_KEY" => "key-for-tests") { example.run }
  end

  def block(type, text = nil)
    double(type: type, text: text)
  end

  def responds_with(content:, stop_reason: :end_turn, stop_details: nil)
    allow(messages).to receive(:create)
      .and_return(double(content: content, stop_reason: stop_reason, stop_details: stop_details))
  end

  def answer
    client.answer(system: "be brief", question: "how is training going?", model: "claude-opus-5")
  end

  describe "the request it builds" do
    before { responds_with(content: [ block(:text, "He has been running well.") ]) }

    def sent
      answer
      expect(messages).to have_received(:create) { |**params| return params }
    end

    # A declared server that no toolset references is rejected before the model
    # sees the request, so the two halves are asserted together.
    it "declares the tool source and points a toolset at it" do
      params = sent

      expect(params[:mcp_servers].sole).to include(type: :url, name: "training-insights",
                                                   url: "https://example.test/mcp")
      expect(params[:tools].sole).to eq(type: :mcp_toolset, mcp_server_name: "training-insights")
    end

    it "authenticates as an ordinary client would" do
      expect(sent[:mcp_servers].sole[:authorization_token]).to eq("key-for-tests")
    end

    # Turning thinking off lets the model write a tool call into its visible text
    # instead of emitting a tool-use block. The turn succeeds, the call never
    # runs, and nothing raises — so cost is controlled with effort instead.
    it "never disables thinking" do
      expect(sent).not_to have_key(:thinking)
      expect(sent[:output_config]).to eq(effort: :low)
    end

    it "opts into a server-side retry when a request is declined" do
      expect(sent[:fallbacks]).to eq(:default)
      expect(sent[:betas]).to include("server-side-fallback-2026-07-01")
    end

    # max_tokens caps thinking and response text together, so it is not the
    # length of the answer.
    it "leaves room for the model to work through several tool calls" do
      expect(sent[:max_tokens]).to be >= 8_192
    end
  end

  describe "reading the response" do
    it "returns the prose" do
      responds_with(content: [ block(:text, "He has been running well.") ])

      expect(answer).to eq("He has been running well.")
    end

    # Content blocks are polymorphic and .text raises on the rest of them.
    it "skips the blocks that are not prose" do
      responds_with(content: [ block(:thinking), block(:text, "Volume is up."), block(:text, "Pace is steady.") ])

      expect(answer).to eq("Volume is up.\n\nPace is steady.")
    end
  end

  describe "when there is no answer to return" do
    # A refusal is a successful response with empty or partial content, so the
    # stop reason has to be read before the content is.
    it "raises rather than returning a refusal's empty content" do
      responds_with(content: [], stop_reason: :refusal, stop_details: double(category: :cyber))

      expect { answer }.to raise_error(described_class::Refused, /cyber/)
    end

    it "raises when a refusal carries no category" do
      responds_with(content: [], stop_reason: :refusal)

      expect { answer }.to raise_error(described_class::Refused)
    end

    it "raises rather than returning a blank answer" do
      responds_with(content: [ block(:thinking) ])

      expect { answer }.to raise_error(described_class::Empty)
    end
  end
end
