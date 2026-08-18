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
    AnalyticalTools::GetTrainingBlockSummary,
    AnalyticalTools::GetPaceProgression,
    AnalyticalTools::GetPersonalRecords,
    AnalyticalTools::GetRaceReadiness,
    AnalyticalTools::SuggestNextRun,
    AnalyticalTools::DescribeRun
  ].freeze

  SERVER_NAME = "training-insights"

  # Delivered on every initialize, so this carries the reading rules that span
  # tools and nothing that belongs in an individual tool's description.
  INSTRUCTIONS = <<~TEXT.strip
    Analytical tools over a single runner's training history.

    Tools return shaped aggregations — volume, load, intensity distribution,
    derived signals and comparison points — not raw activity lists and not
    verdicts. Interpret the numbers yourself; the server does no reasoning.
    get_activities is the one exception and returns individual efforts; reach for
    it only when a question genuinely needs them.

    Units are metric throughout. Pace is seconds per kilometre, so a lower
    number is faster. Efficiency factor rises as fitness improves, while
    aerobic decoupling falls. Any metric may be null when the source data
    lacked what was needed to derive it; sample sizes are reported alongside
    averages so you can judge how much weight a figure carries.

    Pace and efficiency factor are reported both raw and grade-adjusted. The
    grade-adjusted figures normalise for climbing, so they are the ones to
    compare across periods — a route change can move raw pace by more than a
    season of training does. Where a response carries both and they disagree,
    the disagreement is the finding: the routes changed, not the runner.

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

    Two absences are deliberate rather than accidental, and a response will say
    so where it matters. A figure may be missing because the source data did not
    carry what it needed — that is a gap, not a zero. And a delta or
    trend may be suppressed because the sample behind it was too thin to carry
    one; where that happens the response names which side was thin instead of
    returning a bare null.

    No route or GPS data exists anywhere in this server, and no tool reads into
    an activity's raw streams. Anything phrased as a best segment within a run —
    a fastest 5k inside a longer effort, for instance — cannot be answered.
    What a single run looked like from the inside can be. describe_run groups one
    activity's recorded laps into phases — a warmup, a set of repetitions, a
    steady stretch, a cooldown — and reports each phase's distance, pace and
    heart rate, along with the per-rep paces of a set. Individual lap splits are
    not returned, so a single fastest kilometre still cannot be quoted, and the
    response says which lap basis it had.

    Report in prose, in the third person — this is one runner's history, and the
    reader is usually not that runner. Prefer the reading a band label already
    carries over the figure behind it: "moderate drift" lands where "7.4%" does
    not. Quote a number only where it carries the point, which in most answers
    means two or three of them rather than a table. Where a figure is missing or
    a delta was suppressed, say so in a clause and move on.
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
