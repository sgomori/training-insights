# Base class for every analytical tool exposed over MCP.
#
# Tools are deterministic Ruby: they read from the database, shape the result,
# and return it. No Anthropic calls, no HTTP, no AI of any kind happens beneath
# this layer — the client does the reasoning, the tool does the shaping.
#
# Note on autoloading: `app/mcp` is an autoload root, so concrete tools live in
# `app/mcp/analytical_tools/` and resolve as `AnalyticalTools::TheToolName`.
class AnalyticalTool < MCP::Tool
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
    # agrees. Falls back to UTC when no runner is configured yet.
    def runner_timezone
      Runner.current&.timezone.presence || "UTC"
    end

    # Mean of the non-nil values, with the sample size that produced it. A bare
    # average with no count is not self-contained, and nils must never be
    # counted as zero.
    def mean_with_sample(values, precision: 2)
      present = values.compact
      return { value: nil, sample_size: 0 } if present.empty?

      { value: (present.sum.to_f / present.size).round(precision), sample_size: present.size }
    end

    def percent_change(from, to, precision: 1)
      return nil if from.nil? || to.nil? || from.zero?

      (((to - from) / from.to_f) * 100).round(precision)
    end
  end
end
