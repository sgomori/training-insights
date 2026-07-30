# The single source of truth for what this MCP server exposes.
#
# A tool that is not listed here does not exist as far as clients are concerned,
# so adding a tool class is only half of adding a tool.
module ToolRegistry
  TOOLS = [
    AnalyticalTools::GetRecentActivitySummary,
    AnalyticalTools::GetTrainingLoad,
    AnalyticalTools::ComparePeriods,
    AnalyticalTools::GetActivities,
    AnalyticalTools::GetTrainingBlockSummary
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

    Pace and efficiency factor are reported both raw and grade-adjusted. The
    grade-adjusted figures normalise for climbing, so they are the ones to
    compare across periods — a route change can move raw pace by more than a
    season of training does.

    Where a response carries a training_context block, read the period against
    it. Load state changes what a number means: a laboured run in the ninth
    consecutive training day and the same run after a rest week are different
    facts, and only the context block distinguishes them. The same applies to a
    recent race, which depresses the fortnight after it for reasons unrelated to
    fitness.

    Race efforts count fully toward volume and training load, but are excluded
    from averages over aerobic signals, because a maximal effort is not
    comparable with a training run. Each section states the basis it was
    computed on.
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
