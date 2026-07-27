# Authenticates MCP requests against the issued API keys.
#
# Runs as Rack middleware in front of the transport rather than as a controller
# filter, because the transport is mounted directly as a Rack app and never
# passes through the controller stack.
class McpAuthentication
  UNAUTHORIZED_BODY = {
    jsonrpc: "2.0",
    error: { code: -32_001, message: "Unauthorized. Supply a valid API key as a Bearer token." },
    id: nil
  }.freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    api_key = ApiKey.authenticate(presented_token(env))
    return unauthorized if api_key.nil?

    # Best-effort usage tracking; a write failure here must not fail the request.
    touch_last_used(api_key)

    @app.call(env)
  end

  private

  def presented_token(env)
    env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ").strip
  end

  def touch_last_used(api_key)
    api_key.update_column(:last_used_at, Time.current)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("Could not record API key usage: #{e.message}")
  end

  def unauthorized
    [
      401,
      { "content-type" => "application/json" },
      [ UNAUTHORIZED_BODY.to_json ]
    ]
  end
end
