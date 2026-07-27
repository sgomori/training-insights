# The Rack application mounted at /mcp: API key authentication wrapped around
# the Streamable HTTP transport.
#
# The transport runs **stateless**. Its stateful mode keeps session and SSE
# state in process memory, which would tie correctness to running exactly one
# process. Every tool here is read-only, so there is no session worth keeping
# and nothing is given up by going stateless.
class McpEndpoint
  class << self
    def call(env)
      instance.call(env)
    end

    # Rebuilt per request in development so an edited tool is picked up without
    # a restart; memoised everywhere else.
    def instance
      return build if Rails.env.development?

      @instance ||= build
    end

    def build
      McpAuthentication.new(
        MCP::Server::Transports::StreamableHTTPTransport.new(
          ToolRegistry.server,
          stateless: true,
          allowed_hosts: allowed_hosts
        )
      )
    end

    # The transport's DNS rebinding protection trusts only loopback hosts out of
    # the box, so a public deployment must name itself here or every request is
    # rejected with 403 before it reaches a tool.
    def allowed_hosts
      from_env = ENV["MCP_ALLOWED_HOSTS"].to_s.split(",").map(&:strip).reject(&:empty?)
      return from_env if from_env.any?

      hosts = []
      hosts << URI(ENV["MCP_SERVER_URL"]).host if ENV["MCP_SERVER_URL"].present?
      hosts += Rails.application.config.hosts.grep(String)
      hosts << "www.example.com" if Rails.env.test?
      hosts.compact.uniq
    rescue URI::InvalidURIError
      Rails.application.config.hosts.grep(String)
    end
  end
end
