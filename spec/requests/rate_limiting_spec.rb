require "rails_helper"

# The throttles are disabled for the rest of the suite, so this is the only
# place they run. It is also the first place they have ever run: the counters
# live in the cache, and the test environment's null store meant every count
# read back as zero.
RSpec.describe "rate limiting" do
  around do |example|
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

    example.run
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.reset!
  end

  before { create(:runner) }

  describe "chat" do
    def ask
      post chat_path, params: { question: "How is his buildup going?" },
                      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    it "lets an ordinary visitor ask several questions" do
      3.times { ask }

      expect(response).to have_http_status(:ok)
    end

    # This is a budget as much as an abuse control: chat is the only path here
    # that costs money per request.
    it "stops one address running up the bill" do
      11.times { ask }

      expect(response).to have_http_status(:too_many_requests)
    end

    # Turbo declines to render a JSON body for a form submission, so a throttled
    # visitor would otherwise see no bubble and no message — the throttle working
    # and looking like nothing happening.
    it "says so in something the page can render" do
      11.times { ask }

      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include("turbo-stream").and include("as many questions")
    end

    it "says when to come back" do
      11.times { ask }

      expect(response.headers["retry-after"]).to eq("3600")
      expect(response.body).to include("60 minutes")
    end
  end

  describe "the endpoints that were already throttled" do
    it "caps the MCP transport per address" do
      61.times { get "/mcp" }

      expect(response).to have_http_status(:too_many_requests)
    end

    # Those callers read JSON, so they keep the JSON body.
    it "keeps answering them in JSON" do
      61.times { get "/mcp" }

      expect(response.parsed_body["error"]).to match(/Rate limit exceeded/)
    end

    it "caps ingestion per address" do
      31.times { post "/webhooks/activity", params: "{}", headers: { "Content-Type" => "application/json" } }

      expect(response).to have_http_status(:too_many_requests)
    end
  end
end
