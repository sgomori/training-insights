# The single source of truth for what this MCP server exposes.
#
# A tool that is not listed here does not exist as far as clients are concerned,
# so adding a tool class is only half of adding a tool.
module ToolRegistry
  TOOLS = [
    AnalyticalTools::GetRecentActivitySummary
  ].freeze

  SERVER_NAME = "training-insights"

  INSTRUCTIONS = <<~TEXT.strip
    Analytical tools over a single runner's training history.

    Tools return shaped aggregations — volume, load, intensity distribution,
    derived signals and comparison points — not raw activity lists and not
    verdicts. Interpret the numbers yourself; the server does no reasoning.

    Units are metric throughout. Pace is seconds per kilometre, so a lower
    number is faster. Efficiency factor rises as fitness improves, while
    aerobic decoupling falls. Any metric may be null when the source data
    lacked what was needed to derive it; sample sizes are reported alongside
    averages so you can judge how much weight a figure carries.
  TEXT

  def self.tools
    TOOLS
  end

  def self.server
    MCP::Server.new(
      name: SERVER_NAME,
      title: "Training Insights",
      version: "0.1.0",
      instructions: INSTRUCTIONS,
      tools: TOOLS
    )
  end
end
