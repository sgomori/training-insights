# IP-based rate limiting. A baseline against abuse of the public endpoints, not
# a substitute for the API key check in front of the MCP transport.
#
# The thresholds below are deliberate placeholders: the spec calls for setting
# real limits after measuring actual per-call usage, which cannot happen until
# the canonical instance is serving traffic.
class Rack::Attack
  # The MCP endpoint is public and authenticated per key, but an unauthenticated
  # caller can still burn cycles being rejected.
  throttle("mcp/ip", limit: 60, period: 1.minute) do |request|
    request.ip if request.path.start_with?("/mcp")
  end

  # Ingestion is machine-to-machine and low volume: the pipeline delivers one
  # payload per completed activity.
  throttle("webhooks/ip", limit: 30, period: 1.minute) do |request|
    request.ip if request.path.start_with?("/webhooks/")
  end

  self.throttled_responder = lambda do |request|
    retry_after = (request.env["rack.attack.match_data"] || {})[:period].to_i

    [
      429,
      { "content-type" => "application/json", "retry-after" => retry_after.to_s },
      [ { error: "Rate limit exceeded. Retry in #{retry_after} seconds." }.to_json ]
    ]
  end
end
