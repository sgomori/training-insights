# The shared vocabulary for how a metric should be read.
#
# Domain expertise reaches the MCP client through exactly one channel: the wire
# protocol. The reviewer subagents that keep the arithmetic honest are build-time
# only, so anything a client needs in order to interpret a number has to be
# encoded here and shipped alongside it.
#
# The line this module holds: it describes **how to read** a value — its unit,
# which direction is better, where it falls against a published scale, and when
# it is unreliable. It never describes **what to do** about it. "Under 5%
# indicates good aerobic conditioning" is a reading; "your aerobic base is
# solid, keep it up" is a verdict, and verdicts belong to the client.
#
# One definition per metric, used by every tool, so nine tools cannot end up
# explaining efficiency factor three different ways.
module MetricInterpretation
  Definition = Struct.new(:unit, :direction, :guidance, :bands, keyword_init: true)

  # A band is a half-open interval [min, max). Nil bounds are unbounded.
  Band = Struct.new(:label, :min, :max, keyword_init: true) do
    def covers?(value)
      return false if value.nil?
      return false if min && value < min
      return false if max && value >= max

      true
    end

    def to_h
      { label: label, min: min, max: max }.compact
    end
  end

  def self.band(label, min: nil, max: nil) = Band.new(label: label, min: min, max: max)

  DEFINITIONS = {
    aerobic_decoupling_pct: Definition.new(
      unit: "percent",
      direction: "lower_is_better",
      guidance: "Drift in the pace-to-heart-rate ratio between the first and second half of a run. " \
                "Rising values mean heart rate climbed relative to speed.",
      bands: [
        band("well conditioned", max: 5.0),
        band("moderate drift", min: 5.0, max: 10.0),
        band("significant decoupling", min: 10.0)
      ]
    ),

    efficiency_factor: Definition.new(
      unit: "metres per minute per bpm",
      direction: "higher_is_better",
      guidance: "Normalised speed divided by average heart rate. Trends upward as aerobic fitness improves " \
                "and is comparable across activities of the same type.",
      bands: [
        band("implausibly low — check data quality", max: 1.0),
        band("typical for a trained runner", min: 1.0, max: 1.8),
        band("high", min: 1.8, max: 2.5),
        band("implausibly high — check data quality", min: 2.5)
      ]
    ),

    average_pace_per_km: Definition.new(
      unit: "seconds per kilometre",
      direction: "lower_is_faster",
      guidance: "A decreasing value over time means the runner is getting faster. " \
                "Compare only against efforts of similar type and distance.",
      bands: []
    ),

    avg_grade_adjusted_pace_per_km: Definition.new(
      unit: "seconds per kilometre",
      direction: "lower_is_faster",
      guidance: "Pace normalised to flat-equivalent terrain, so efforts on different routes are comparable. " \
                "Faster than raw pace by the amount the climbing cost. Compare this, not raw pace, when " \
                "judging whether the runner is getting faster.",
      bands: []
    ),

    grade_adjusted_efficiency_factor: Definition.new(
      unit: "metres per minute per bpm",
      direction: "higher_is_better",
      guidance: "Efficiency factor computed from grade-adjusted rather than raw pace. On hilly routes this " \
                "is the fairer read of aerobic fitness, because raw efficiency factor penalises climbing.",
      bands: [
        band("implausibly low — check data quality", max: 1.0),
        band("typical for a trained runner", min: 1.0, max: 1.8),
        band("high", min: 1.8, max: 2.5),
        band("implausibly high — check data quality", min: 2.5)
      ]
    ),

    elevation_gain_per_km: Definition.new(
      unit: "metres per kilometre",
      direction: "context_dependent",
      guidance: "Climbing per kilometre, describing the terrain rather than the runner. Use it to check " \
                "whether a change in pace reflects fitness or a change in route.",
      bands: [
        band("flat", max: 5.0),
        band("gently rolling", min: 5.0, max: 15.0),
        band("rolling", min: 15.0, max: 30.0),
        band("hilly", min: 30.0, max: 60.0),
        band("mountainous", min: 60.0)
      ]
    ),

    cardiac_drift_bpm: Definition.new(
      unit: "bpm",
      direction: "lower_is_better",
      guidance: "Heart rate rise from the first quarter of a run to the last. Only meaningful on " \
                "steady-state efforts, because pace is not controlled for.",
      bands: [
        band("normal", max: 25.0),
        band("elevated", min: 25.0, max: 30.0),
        band("extreme", min: 30.0)
      ]
    ),

    pace_cv: Definition.new(
      unit: "coefficient of variation",
      direction: "context_dependent",
      guidance: "Pace variability within a run. Low values indicate an even effort; high values indicate " \
                "intervals or varied terrain. Use it to judge whether pace-sensitive metrics apply.",
      bands: [
        band("very consistent", max: 0.05),
        band("normal variation", min: 0.05, max: 0.15),
        band("variable", min: 0.15, max: 0.20),
        band("highly variable — intervals or trail", min: 0.20)
      ]
    ),

    acute_chronic_ratio: Definition.new(
      unit: "ratio",
      direction: "context_dependent",
      guidance: "Trailing 7-day load against the chronic weekly average. Near 1.0 means load is steady; " \
                "sustained excursions in either direction represent a change in training stress.",
      bands: [
        band("detraining or taper", max: 0.8),
        band("typical maintenance range", min: 0.8, max: 1.3),
        band("building", min: 1.3, max: 1.5),
        band("sharp load increase", min: 1.5)
      ]
    ),

    tss_score: Definition.new(
      unit: "TSS",
      direction: "context_dependent",
      guidance: "Heart-rate-derived training stress for the activity. Duration and intensity weighted; " \
                "sums meaningfully across activities.",
      bands: []
    ),

    training_monotony: Definition.new(
      unit: "ratio",
      direction: "lower_is_better",
      guidance: "Foster's monotony: mean daily load for a week divided by the standard deviation of daily " \
                "load across its seven days, rest days included as zero. High values mean every day looked " \
                "the same, which is the pattern associated with accumulating fatigue even at moderate volume.",
      bands: [
        band("varied", max: 1.5),
        band("moderately monotonous", min: 1.5, max: 2.0),
        band("monotonous", min: 2.0)
      ]
    ),

    training_strain: Definition.new(
      unit: "TSS x monotony",
      direction: "context_dependent",
      guidance: "Weekly load multiplied by that week's monotony, so a monotonous week counts for more than " \
                "its volume alone. Read it as a relative figure across this runner's own weeks. The " \
                "published strain thresholds come from session-RPE load units and do not transfer to a " \
                "heart-rate-derived TSS, so no reference bands are given.",
      bands: []
    ),

    weekly_ramp_rate_pct: Definition.new(
      unit: "percent per week",
      direction: "context_dependent",
      guidance: "Mean week-over-week change in weekly training load. Conventional guidance treats sustained " \
                "increases beyond 10% a week as an aggressive build; a single week above it during a planned " \
                "step-up is a different fact from four in a row.",
      bands: [
        band("reducing", max: 0.0),
        band("conservative build", min: 0.0, max: 5.0),
        band("moderate build", min: 5.0, max: 10.0),
        band("aggressive build", min: 10.0)
      ]
    ),

    long_run_pct_of_race_distance: Definition.new(
      unit: "percent of race distance",
      direction: "context_dependent",
      guidance: "The buildup's longest run as a share of the race distance. What counts as adequate depends " \
                "entirely on the distance: marathon programmes conventionally peak at 70-85% of race " \
                "distance, while a 10k buildup routinely runs 150-200% of it. No reference bands are given, " \
                "because one set of them would misread every distance but the one it was drawn from.",
      bands: []
    ),

    taper_ratio: Definition.new(
      unit: "ratio",
      direction: "context_dependent",
      guidance: "Most recent week's volume against the peak week of the buildup. Describes where in the " \
                "load cycle the runner currently is; it says nothing about whether the taper was well timed.",
      bands: [
        band("deep taper or interruption", max: 0.5),
        band("tapering", min: 0.5, max: 0.7),
        band("easing", min: 0.7, max: 0.9),
        band("at peak volume", min: 0.9, max: 1.1),
        band("above the previous peak", min: 1.1)
      ]
    ),

    hrv_ms: Definition.new(
      unit: "milliseconds",
      direction: "higher_is_better",
      guidance: "Overnight heart rate variability. Only readable against this runner's own trailing " \
                "baseline: absolute values vary by a factor of three between individuals, so no reference " \
                "bands are given. A single reading well below baseline is a fatigue or illness signal; a " \
                "sustained decline is a different fact from one bad night.",
      bands: []
    ),

    resting_hr_bpm: Definition.new(
      unit: "bpm",
      direction: "lower_is_better",
      guidance: "Overnight resting heart rate. Like HRV, meaningful only against the runner's own " \
                "baseline, so no reference bands are given. An elevation of several beats over baseline " \
                "commonly accompanies incomplete recovery, illness or heat.",
      bands: []
    ),

    sleep_score: Definition.new(
      unit: "score out of 100",
      direction: "higher_is_better",
      guidance: "The device's composite sleep score. Unlike HRV and resting heart rate this is already " \
                "normalised, so the published bands apply directly.",
      bands: [
        band("poor", max: 60.0),
        band("fair", min: 60.0, max: 80.0),
        band("good", min: 80.0, max: 90.0),
        band("excellent", min: 90.0)
      ]
    )
  }.freeze

  # Builds the response fragment for a metric: the value, how to read it, and
  # any caveat that applies to this particular reading.
  #
  # `caveats` is how context enters. A number can be arithmetically correct and
  # still not mean what it appears to — cardiac drift on an interval session
  # being the standing example — and the client cannot know that unless the
  # server says so next to the value.
  def self.describe(metric, value:, sample_size: nil, caveats: [])
    definition = DEFINITIONS.fetch(metric)

    {
      value: value,
      sample_size: sample_size,
      unit: definition.unit,
      direction: definition.direction,
      guidance: definition.guidance,
      band: band_label_for(definition, value),
      reference_bands: definition.bands.map(&:to_h).presence,
      caveats: caveats.presence
    }.compact
  end

  # Which published band the value falls in. A factual classification against a
  # documented scale, not a judgement about the runner.
  def self.band_label_for(definition, value)
    definition.bands.find { |b| b.covers?(value) }&.label
  end

  def self.known?(metric) = DEFINITIONS.key?(metric)
end
