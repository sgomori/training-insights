module AnalyticalTools
  # The canonical recent-training overview. This is the tool the website's
  # pre-generated content is built from, and the reference implementation the
  # rest of the inventory follows.
  #
  # The aggregations themselves live in TrainingWindow, which every tool shares.
  # What is left here is this tool's own work: the comparison against the
  # preceding period, and the notable signals surfaced from both.
  class GetRecentActivitySummary < AnalyticalTool
    tool_name "get_recent_activity_summary"

    description <<~TEXT.strip
      A shaped overview of the runner's recent training: volume, terrain,
      training load, duration-weighted intensity distribution, aerobic fitness
      signals both raw and grade-adjusted, and a comparison against the
      immediately preceding period of equal length. Every response also carries
      the runner's current load state, so a single period can be read against
      what preceded it. Returns aggregations and surfaced signals rather than a
      list of activities.
    TEXT

    input_schema(
      properties: {
        days: {
          type: "integer",
          description: "Length of the period to summarise, counting back from today. Defaults to 28.",
          minimum: 1,
          maximum: 365
        }
      },
      required: []
    )

    DEFAULT_DAYS = 28

    # Below this the terrain cost is inside the noise of pace measurement and
    # not worth surfacing.
    NOTABLE_TERRAIN_COST_SECONDS = 5.0

    # Decoupling above this is conventionally read as significant drift rather
    # than normal variation, and is worth naming in the signals.
    NOTABLE_DECOUPLING_PCT = 10.0

    # A pace shift smaller than this is inside the noise of route and weather.
    NOTABLE_PACE_DELTA_SECONDS = 5.0

    class << self
      def call(days: nil, server_context: nil)
        days = days_param(days, default: DEFAULT_DAYS)
        zone = runner_time_zone
        context = TrainingContext.current(zone: zone)

        current = TrainingWindow.ending(zone.today, days: days, zone: zone)
        previous = TrainingWindow.ending(zone.today - days, days: days, zone: zone)

        shaped(
          period: current.period,
          training_context: context.to_h,
          volume: current.volume,
          terrain: current.terrain,
          training_load: current.load,
          intensity_distribution: current.intensity_distribution,
          aerobic_signals: current.aerobic_signals,
          comparison_to_previous_period: comparison(current, previous),
          notable: notable_signals(current, previous, context)
        )
      end

      private

      def comparison(current, previous)
        {
          note: "Compared against the immediately preceding period of equal length. " \
                "A negative pace delta is faster. Prefer the grade-adjusted delta: it is the one " \
                "that isolates fitness from a change of route.",
          previous_activity_count: previous.activities.size,
          activity_count_change: current.activities.size - previous.activities.size,
          distance_change_pct: percent_change(previous.total_distance_meters, current.total_distance_meters),
          tss_change_pct: percent_change(previous.total_tss, current.total_tss),
          pace_change_seconds_per_km: pace_delta(current, previous, :average_pace_per_km),
          grade_adjusted_pace_change_seconds_per_km:
            pace_delta(current, previous, :avg_grade_adjusted_pace_per_km),
          elevation_gain_per_km_change: percent_change(previous.gain_per_km, current.gain_per_km)
        }
      end

      # Race efforts are left out of the pace deltas for the same reason they are
      # left out of the aerobic averages: a maximal effort in one of the two
      # periods moves the average by more than any training change would, and
      # this delta exists to isolate fitness. It would not be caught by a pace
      # variability guard either, because a well-executed race is evenly paced.
      #
      # Suppressed rather than reported when either side is too thin to trend, so
      # a two-run period cannot produce a confident-looking number.
      def pace_delta(current, previous, column)
        now = current.mean(column, precision: 1)
        before = previous.mean(column, precision: 1)
        return nil if now[:value].nil? || before[:value].nil?
        return nil if now[:sample_size] < TrainingWindow::MIN_SAMPLE_FOR_TREND
        return nil if before[:sample_size] < TrainingWindow::MIN_SAMPLE_FOR_TREND

        (now[:value] - before[:value]).round(1)
      end

      def notable_signals(current, previous, context)
        activities = current.activities
        signals = []

        if current.empty?
          signals << "No activities recorded in the last #{current.days} days."
          return signals
        end

        if activities.size < TrainingWindow::MIN_SAMPLE_FOR_TREND
          signals << "Only #{activities.size} #{'activity'.pluralize(activities.size)} in this period — " \
                     "averages and comparisons are unreliable."
        end

        signals.concat(load_state_signals(context))
        signals.concat(data_quality_signals(current))
        signals.concat(race_signals(current))

        cost = current.terrain_cost_seconds_per_km
        if cost && cost >= NOTABLE_TERRAIN_COST_SECONDS
          signals << "Terrain cost about #{cost}s/km over this period — raw pace understates the effort."
        end

        signals.concat(pace_trend_signals(current, previous))
        signals
      end

      def load_state_signals(context)
        signals = []

        acwr = context.acute_chronic_ratio
        if acwr && (acwr > 1.5 || acwr < 0.8)
          band = MetricInterpretation.describe(:acute_chronic_ratio, value: acwr)[:band]
          signals << "Acute:chronic load ratio is #{acwr} (#{band}), outside the typical 0.8-1.3 range."
        end

        unless context.sufficient_history_for_chronic_load?
          span = context.history_spans_days
          signals << "Only #{span} #{'day'.pluralize(span)} of history exist, " \
                     "so the chronic load figure is not yet a true chronic load."
        end

        streak = context.consecutive_training_days
        if streak >= 7 && context.days_since_last_activity.to_i.zero?
          signals << "#{streak} consecutive training days with no rest day."
        end

        signals
      end

      def data_quality_signals(window)
        activities = window.activities
        signals = []

        missing = activities.count { |a| a.tss_score.nil? }
        if missing.positive?
          signals << "#{missing} of #{activities.size} #{'activity'.pluralize(activities.size)} " \
                     "#{missing == 1 ? 'has' : 'have'} no TSS, so training load is understated."
        end

        decoupling = window.mean(:aerobic_decoupling_pct)
        if decoupling[:value] &&
           decoupling[:sample_size] >= TrainingWindow::MIN_SAMPLE_FOR_TREND &&
           decoupling[:value] > NOTABLE_DECOUPLING_PCT
          signals << "Average aerobic decoupling is #{decoupling[:value]}%, " \
                     "above the #{NOTABLE_DECOUPLING_PCT.to_i}% threshold for significant decoupling."
        end

        # Counted over training efforts only, so a race already withheld as a
        # maximal effort is not also reported as excluded for its pacing.
        training = window.training_only
        variable = training.count { |a| a.pace_cv && a.pace_cv > TrainingWindow::STEADY_STATE_PACE_CV_MAX }
        if variable.positive?
          signals << "#{variable} of #{training.size} training #{'activity'.pluralize(training.size)} " \
                     "had highly variable pace, indicating structured or off-road sessions. " \
                     "Pace-sensitive metrics exclude them."
        end

        signals
      end

      def race_signals(window)
        window.races.map do |activity|
          race = activity.race
          "Raced #{race.name} on #{race.race_date} " \
            "(#{(race.distance_meters / 1000.0).round(1)}km). " \
            "Counted in volume and load, excluded from the aerobic averages."
        end
      end

      # Raw and grade-adjusted pace are reported together when they disagree,
      # because the disagreement is the finding: pace that only improved on the
      # raw figure means the routes got flatter, not that the runner got faster.
      def pace_trend_signals(current, previous)
        raw = pace_delta(current, previous, :average_pace_per_km)
        adjusted = pace_delta(current, previous, :avg_grade_adjusted_pace_per_km)
        signals = []

        if adjusted && adjusted.abs >= NOTABLE_PACE_DELTA_SECONDS
          signals << "Grade-adjusted pace is #{adjusted.abs}s/km #{adjusted.negative? ? 'faster' : 'slower'} " \
                     "than the preceding period, with terrain accounted for."
        elsif raw && raw.abs >= NOTABLE_PACE_DELTA_SECONDS
          signals << "Average pace is #{raw.abs}s/km #{raw.negative? ? 'faster' : 'slower'} than the preceding period."
        end

        if raw && adjusted && (raw - adjusted).abs >= NOTABLE_PACE_DELTA_SECONDS
          signals << "Raw and grade-adjusted pace trends disagree by #{(raw - adjusted).abs.round(1)}s/km, " \
                     "so the routes changed in difficulty between the two periods."
        end

        signals
      end
    end
  end
end
