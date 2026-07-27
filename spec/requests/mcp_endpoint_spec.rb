require "rails_helper"

RSpec.describe "MCP endpoint" do
  let!(:token) { ApiKey.generate!(name: "test-client") }

  def rpc(method, params: nil, token: nil, id: 1)
    body = { jsonrpc: "2.0", id: id, method: method }
    body[:params] = params if params

    headers = { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" }
    headers["Authorization"] = "Bearer #{token}" if token

    post "/mcp", params: body.to_json, headers: headers
  end

  describe "authentication" do
    it "rejects a request with no API key" do
      rpc("tools/list")

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "message")).to match(/Unauthorized/)
    end

    it "rejects an unknown API key" do
      rpc("tools/list", token: "not-a-real-key")

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a revoked API key" do
      ApiKey.authenticate(token).revoke!

      rpc("tools/list", token: token)

      expect(response).to have_http_status(:unauthorized)
    end

    it "records usage of an accepted key" do
      expect { rpc("tools/list", token: token) }
        .to change { ApiKey.find_by(token_digest: ApiKey.digest(token)).last_used_at }
        .from(nil)
    end
  end

  describe "tools/list" do
    it "advertises the registered tools with their schemas" do
      rpc("tools/list", token: token)

      expect(response).to have_http_status(:ok)
      tools = response.parsed_body.dig("result", "tools")

      expect(tools.map { |t| t["name"] }).to include("get_recent_activity_summary")

      summary = tools.find { |t| t["name"] == "get_recent_activity_summary" }
      expect(summary["inputSchema"]["properties"]).to have_key("days")
      expect(summary["description"]).to be_present
    end

    it "advertises every tool as read-only" do
      rpc("tools/list", token: token)

      response.parsed_body.dig("result", "tools").each do |tool|
        expect(tool.dig("annotations", "readOnlyHint")).to be(true),
          "expected #{tool['name']} to be annotated read-only"
      end
    end
  end

  describe "tools/call" do
    before { create_list(:activity, 4) }

    it "returns shaped structured content" do
      rpc("tools/call", params: { name: "get_recent_activity_summary", arguments: { days: 28 } }, token: token)

      expect(response).to have_http_status(:ok)
      result = response.parsed_body["result"]

      expect(result["isError"]).to be_falsey
      expect(result["structuredContent"]).to include("period", "volume", "training_load",
        "intensity_distribution", "aerobic_signals", "comparison_to_previous_period", "notable")
    end

    it "does not return a raw activity list" do
      rpc("tools/call", params: { name: "get_recent_activity_summary", arguments: {} }, token: token)

      expect(response.parsed_body["result"]["structuredContent"]).not_to have_key("activities")
    end

    it "reports an unknown tool as an error rather than crashing" do
      rpc("tools/call", params: { name: "no_such_tool", arguments: {} }, token: token)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to have_key("error").or satisfy { |b| b.dig("result", "isError") }
    end
  end
end
