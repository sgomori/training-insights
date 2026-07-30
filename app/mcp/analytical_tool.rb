# Base class for every analytical tool exposed over MCP.
#
# Tools are deterministic Ruby: they read from the database, shape the result,
# and return it. No Anthropic calls, no HTTP, no AI of any kind happens beneath
# this layer — the client does the reasoning, the tool does the shaping.
#
# Note on autoloading: `app/mcp` is an autoload root, so concrete tools live in
# `app/mcp/analytical_tools/` and resolve as `AnalyticalTools::TheToolName`.
class AnalyticalTool < MCP::Tool
  # mean_with_sample, percent_change and standard_deviation as class methods, so
  # every tool shares one implementation of the nil and sample-size rules.
  extend MetricMath

  # Every tool on this server is read-only and safe to retry. MCP::Tool.inherited
  # resets annotations on each subclass, so they are re-applied here rather than
  # declared once on this class — otherwise every concrete tool would silently
  # advertise the default read_only_hint of false.
  READ_ONLY_ANNOTATIONS = {
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  }.freeze

  def self.inherited(subclass)
    super
    subclass.annotations(READ_ONLY_ANNOTATIONS.dup)
  end

  class << self
    # Wraps a shaped Hash as an MCP tool response, carrying it both as JSON text
    # (for clients that read content) and as structured content.
    def shaped(payload)
      MCP::Tool::Response.new(
        [ { type: "text", text: JSON.pretty_generate(payload) } ],
        structured_content: payload
      )
    end

    def failure(message)
      MCP::Tool::Response.new([ { type: "text", text: message } ], error: true)
    end

    # The runner's configured timezone, so every period boundary in every tool
    # agrees.
    def runner_time_zone
      Runner.current_time_zone
    end

    # A period length is clamped rather than rejected. A client asking for ten
    # years of history has made a reasonable request against an unreasonable
    # corpus; answering for the longest window supported is more useful than an
    # error, and the response states the window it actually used.
    def days_param(value, default:, min: 1, max: 365)
      return default if value.nil?

      value.to_i.clamp(min, max)
    end
  end
end
