module AnalyticalTools
  # The canonical recent-training overview. This is the tool the website's
  # pre-generated content is built from, and the reference implementation the
  # rest of the inventory follows.
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

    # Below this many contributing activities, trends and averages are noise.
    MIN_SAMPLE_FOR_TREND = 3

    # Pace variability above this indicates intervals or varied terrain rather
    # than a steady effort. Metrics that assume even pacing are not meaningful
    # past it — see the cardiac drift signal below.
    STEADY_STATE_PACE_CV_MAX = 0.20

    # Below this the terrain cost is inside the noise of pace measurement and
    # not worth surfacing.
    NOTABLE_TERRAIN_COST_SECONDS = 5.0

    class << self
      def call(days: DEFAULT_DAYS, server_context: nil)
        days = days.to_i.clamp(1, 365)
        zone = runner_time_zone
        context = TrainingContext.current(zone: zone)

        current = period_ending(zone.today, days, zone)
        previous = period_ending(zone.today - days, days, zone)

        shaped(
          period: describe_period(current, days, zone),
          training_context: context.to_h,
          volume: volume_for(current),
          terrain: terrain_for(current),
          training_load: training_load_for(current, days),
          intensity_distribution: intensity_for(current),
          aerobic_signals: aerobic_signals_for(current),
          comparison_to_previous_period: comparison(current, previous),
          notable: notable_signals(current, previous, days, context)
        )
      end

      private

      # Returns the activities starting within the window, as a materialised
      # array — every section below walks the same set, so loading it once
      # avoids re-querying per section.
      def period_ending(last_day, days, zone)
        first_day = last_day - (days - 1)
        Activity
          .starting_between(zone.parse(first_day.to_s).beginning_of_day, zone.parse(last_day.to_s).end_of_day)
          .includes(:race)
          .chronological
          .to_a
      end

      def describe_period(activities, days, zone)
        {
          days: days,
          from: (zone.today - (days - 1)).to_s,
          to: zone.today.to_s,
          timezone: zone.name,
          activity_count: activities.size
        }
      end

      def volume_for(activities)
        distances = activities.filter_map(&:distance_meters)
        durations = activities.filter_map(&:duration_seconds)

        {
          activity_count: activities.size,
          total_distance_km: (distances.sum / 1000.0).round(1),
          total_duration_hours: (durations.sum / 3600.0).round(1),
          average_distance_km: distances.empty? ? nil : (distances.sum / distances.size / 1000.0).round(1),
          longest_run_km: distances.empty? ? nil : (distances.max / 1000.0).round(1),
          days_with_activity: activities.map { |a| a.started_at.to_date }.uniq.size
        }
      end

      # Terrain is reported separately from volume because it qualifies every
      # pace figure below it. The same 10k is a different effort on a hill, and
      # the client has no way to know which it was looking at otherwise.
      #
      # The ratio is taken over activities carrying both figures, so a run with
      # no altitude data cannot drag the average toward flat.
      def terrain_for(activities)
        measured = activities.select { |a| a.elevation_gain_meters && a.distance_meters.to_f.positive? }
        gain = measured.sum(&:elevation_gain_meters)
        distance_km = measured.sum(&:distance_meters) / 1000.0

        {
          total_elevation_gain_m: gain.round,
          elevation_gain_per_km: MetricInterpretation.describe(
            :elevation_gain_per_km,
            value: distance_km.positive? ? (gain / distance_km).round(1) : nil,
            sample_size: measured.size
          )
        }
      end

      # Load figures scoped to the requested period. The acute:chronic ratio is
      # deliberately not here: it belongs to the runner's present state, not to
      # an arbitrary window, and lives in training_context so that asking for a
      # 90-day summary cannot change what the ratio says.
      def training_load_for(activities, days)
        scored = activities.select(&:tss_score)
        total = scored.sum(&:tss_score)

        {
          total_tss: total.round(1),
          average_daily_tss: (total / days.to_f).round(1),
          # Load is understated by exactly this many activities, because the
          # pipeline could not derive a TSS for them.
          activities_missing_tss: activities.size - scored.size
        }
      end

      # Zone percentages are per-activity and must be weighted by duration
      # before they can be combined. Averaging the percentages would count a
      # 20-minute recovery jog equally with a 3-hour long run.
      def intensity_for(activities)
        {
          basis: "duration_weighted",
          hr_zones_pct: weighted_zones(activities, :hr_zone_distribution),
          pace_zones_pct: weighted_zones(activities, :pace_zone_distribution)
        }
      end

      def weighted_zones(activities, column)
        contributing = activities.select { |a| a.public_send(column).present? && a.duration_seconds.to_f.positive? }
        return { zones: nil, activities_contributing: 0 } if contributing.empty?

        total_duration = contributing.sum(&:duration_seconds)
        totals = Hash.new(0.0)

        contributing.each do |activity|
          activity.public_send(column).each do |zone, pct|
            totals[zone] += pct.to_f * activity.duration_seconds
          end
        end

        {
          zones: totals.transform_values { |v| (v / total_duration).round(1) },
          activities_contributing: contributing.size,
          hours_contributing: (total_duration / 3600.0).round(1)
        }
      end

      # Every signal ships with the shared reading guidance from
      # MetricInterpretation, so the client is never handed a bare number it has
      # no way to scale.
      #
      # Pace and efficiency factor appear twice: once raw, once grade-adjusted.
      # The pipeline normalises both against the altitude stream, and the
      # adjusted figure is the one that survives a change of route.
      #
      # Races are excluded here and nowhere else. A race is real load and real
      # volume, so it counts fully in those sections, but it is a maximal effort
      # and its aerobic figures are not comparable with a training run's. It
      # would not be caught by the steady-state filter either: a well-executed
      # race is evenly paced, so it passes the pace variability guard while
      # distorting every average it enters.
      def aerobic_signals_for(activities)
        training = activities.reject(&:race?)
        excluded = activities.size - training.size

        {
          basis: aerobic_basis(excluded),
          aerobic_decoupling_pct: MetricInterpretation.describe(
            :aerobic_decoupling_pct, **mean_with_sample(training.map(&:aerobic_decoupling_pct))
          ),
          efficiency_factor: MetricInterpretation.describe(
            :efficiency_factor, **mean_with_sample(training.map(&:efficiency_factor), precision: 3)
          ),
          grade_adjusted_efficiency_factor: MetricInterpretation.describe(
            :grade_adjusted_efficiency_factor,
            **mean_with_sample(training.map(&:grade_adjusted_efficiency_factor), precision: 3)
          ),
          average_pace_per_km: MetricInterpretation.describe(
            :average_pace_per_km, **mean_with_sample(training.map(&:average_pace_per_km), precision: 1)
          ),
          avg_grade_adjusted_pace_per_km: MetricInterpretation.describe(
            :avg_grade_adjusted_pace_per_km,
            **mean_with_sample(training.map(&:avg_grade_adjusted_pace_per_km), precision: 1)
          ),
          pace_variability: MetricInterpretation.describe(
            :pace_cv, **mean_with_sample(training.map(&:pace_cv), precision: 3)
          ),
          cardiac_drift_bpm: cardiac_drift_signal(training)
        }
      end

      def aerobic_basis(excluded)
        return "All activities in the period." if excluded.zero?

        "Training efforts only. #{excluded} race #{'effort'.pluralize(excluded)} excluded, " \
          "because a maximal effort is not comparable with a training run."
      end

      # Cardiac drift assumes an even effort — on an interval session the figure
      # is arithmetically correct and analytically meaningless. Rather than
      # averaging everything and appending a warning, the average is taken over
      # steady-state efforts only and the response says what was set aside.
      def cardiac_drift_signal(activities)
        measured = activities.select(&:cardiac_drift_bpm)
        steady = measured.select { |a| a.pace_cv && a.pace_cv <= STEADY_STATE_PACE_CV_MAX }
        variable = measured.count { |a| a.pace_cv && a.pace_cv > STEADY_STATE_PACE_CV_MAX }
        unclassified = measured.count { |a| a.pace_cv.nil? }

        caveats = [ "Averaged over steady-state efforts only." ]
        if variable.positive?
          caveats << "#{variable} #{'activity'.pluralize(variable)} excluded as non-steady-state " \
                     "(pace variability above #{STEADY_STATE_PACE_CV_MAX})."
        end
        if unclassified.positive?
          caveats << "#{unclassified} excluded because pace variability could not be derived."
        end

        MetricInterpretation.describe(
          :cardiac_drift_bpm,
          **mean_with_sample(steady.map(&:cardiac_drift_bpm), precision: 1),
          caveats: caveats
        )
      end

      def comparison(current, previous)
        current_distance = current.filter_map(&:distance_meters).sum
        previous_distance = previous.filter_map(&:distance_meters).sum
        current_tss = current.filter_map(&:tss_score).sum
        previous_tss = previous.filter_map(&:tss_score).sum

        {
          note: "Compared against the immediately preceding period of equal length. " \
                "A negative pace delta is faster. Prefer the grade-adjusted delta: it is the one " \
                "that isolates fitness from a change of route.",
          previous_activity_count: previous.size,
          activity_count_change: current.size - previous.size,
          distance_change_pct: percent_change(previous_distance, current_distance),
          tss_change_pct: percent_change(previous_tss, current_tss),
          pace_change_seconds_per_km: pace_delta(current, previous, :average_pace_per_km),
          grade_adjusted_pace_change_seconds_per_km:
            pace_delta(current, previous, :avg_grade_adjusted_pace_per_km),
          elevation_gain_per_km_change: percent_change(
            gain_per_km(previous), gain_per_km(current)
          )
        }
      end

      def pace_delta(current, previous, column)
        now = mean_with_sample(current.map(&column), precision: 1)
        before = mean_with_sample(previous.map(&column), precision: 1)
        return nil if now[:value].nil? || before[:value].nil?
        return nil if now[:sample_size] < MIN_SAMPLE_FOR_TREND || before[:sample_size] < MIN_SAMPLE_FOR_TREND

        (now[:value] - before[:value]).round(1)
      end

      def gain_per_km(activities)
        measured = activities.select { |a| a.elevation_gain_meters && a.distance_meters.to_f.positive? }
        distance_km = measured.sum(&:distance_meters) / 1000.0
        return nil unless distance_km.positive?

        (measured.sum(&:elevation_gain_meters) / distance_km).round(1)
      end

      # How much the terrain cost, in seconds per kilometre: the gap between raw
      # pace and its flat-equivalent, over activities carrying both.
      def terrain_cost_seconds_per_km(activities)
        measured = activities.select { |a| a.average_pace_per_km && a.avg_grade_adjusted_pace_per_km }
        return nil if measured.empty?

        raw = measured.sum(&:average_pace_per_km) / measured.size
        adjusted = measured.sum(&:avg_grade_adjusted_pace_per_km) / measured.size
        (raw - adjusted).round(1)
      end

      def notable_signals(current, previous, days, context)
        signals = []

        if current.empty?
          signals << "No activities recorded in the last #{days} days."
          return signals
        end

        if current.size < MIN_SAMPLE_FOR_TREND
          signals << "Only #{current.size} #{'activity'.pluralize(current.size)} in this period — averages and comparisons are unreliable."
        end

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

        missing = current.count { |a| a.tss_score.nil? }
        if missing.positive?
          signals << "#{missing} of #{current.size} #{'activity'.pluralize(current.size)} " \
                     "#{missing == 1 ? 'has' : 'have'} no TSS, so training load is understated."
        end

        decoupling = mean_with_sample(current.map(&:aerobic_decoupling_pct))
        if decoupling[:value] && decoupling[:sample_size] >= MIN_SAMPLE_FOR_TREND && decoupling[:value] > 10
          signals << "Average aerobic decoupling is #{decoupling[:value]}%, above the 10% threshold for significant decoupling."
        end

        # Counted over training efforts only, so a race already withheld as a
        # maximal effort is not also reported as excluded for its pacing.
        training = current.reject(&:race?)
        variable = training.count { |a| a.pace_cv && a.pace_cv > STEADY_STATE_PACE_CV_MAX }
        if variable.positive?
          signals << "#{variable} of #{training.size} training #{'activity'.pluralize(training.size)} had highly variable pace, " \
                     "indicating structured or off-road sessions. Pace-sensitive metrics exclude them."
        end

        current.select(&:race?).each do |activity|
          race = activity.race
          signals << "Raced #{race.name} on #{race.race_date} " \
                     "(#{(race.distance_meters / 1000.0).round(1)}km). " \
                     "Counted in volume and load, excluded from the aerobic averages."
        end

        cost = terrain_cost_seconds_per_km(current)
        if cost && cost >= NOTABLE_TERRAIN_COST_SECONDS
          signals << "Terrain cost about #{cost}s/km over this period — raw pace understates the effort."
        end

        signals.concat(pace_trend_signals(current, previous))
        signals
      end

      # Raw and grade-adjusted pace are reported together when they disagree,
      # because the disagreement is the finding: pace that only improved on the
      # raw figure means the routes got flatter, not that the runner got faster.
      def pace_trend_signals(current, previous)
        raw = pace_delta(current, previous, :average_pace_per_km)
        adjusted = pace_delta(current, previous, :avg_grade_adjusted_pace_per_km)
        signals = []

        if adjusted && adjusted.abs >= 5
          signals << "Grade-adjusted pace is #{adjusted.abs}s/km #{adjusted.negative? ? 'faster' : 'slower'} " \
                     "than the preceding period, with terrain accounted for."
        elsif raw && raw.abs >= 5
          signals << "Average pace is #{raw.abs}s/km #{raw.negative? ? 'faster' : 'slower'} than the preceding period."
        end

        if raw && adjusted && (raw - adjusted).abs >= 5
          signals << "Raw and grade-adjusted pace trends disagree by #{(raw - adjusted).abs.round(1)}s/km, " \
                     "so the routes changed in difficulty between the two periods."
        end

        signals
      end
    end
  end
end
