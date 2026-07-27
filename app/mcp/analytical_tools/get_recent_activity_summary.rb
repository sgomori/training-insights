module AnalyticalTools
  # The canonical recent-training overview. This is the tool the website's
  # pre-generated content is built from, and the reference implementation the
  # rest of the inventory follows.
  class GetRecentActivitySummary < AnalyticalTool
    tool_name "get_recent_activity_summary"

    description <<~TEXT.strip
      A shaped overview of the runner's recent training: volume, training load
      with its acute:chronic ratio, duration-weighted intensity distribution,
      aerobic fitness signals, and a comparison against the immediately
      preceding period of equal length. Returns aggregations and surfaced
      signals rather than a list of activities.
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

    class << self
      def call(days: DEFAULT_DAYS, server_context: nil)
        days = days.to_i.clamp(1, 365)
        zone = ActiveSupport::TimeZone[runner_timezone] || ActiveSupport::TimeZone["UTC"]

        current = period_ending(zone.today, days, zone)
        previous = period_ending(zone.today - days, days, zone)

        shaped(
          period: describe_period(current, days, zone),
          volume: volume_for(current),
          training_load: training_load_for(current, days, zone),
          intensity_distribution: intensity_for(current),
          aerobic_signals: aerobic_signals_for(current),
          comparison_to_previous_period: comparison(current, previous),
          notable: notable_signals(current, previous, days, zone)
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
          total_elevation_gain_m: activities.filter_map(&:elevation_gain_meters).sum.round,
          average_distance_km: distances.empty? ? nil : (distances.sum / distances.size / 1000.0).round(1),
          longest_run_km: distances.empty? ? nil : (distances.max / 1000.0).round(1),
          days_with_activity: activities.map { |a| a.started_at.to_date }.uniq.size
        }
      end

      # Acute load is the trailing 7-day total. Chronic load is normalised to a
      # weekly figure so the ratio sits near 1.0 for steady training — dividing
      # a 7-day sum by a 28-day sum would report ~0.25 instead.
      #
      # The acute window is bounded by calendar days in the runner's timezone,
      # matching how the reporting period itself is derived. A rolling
      # `Time.current - 7.days` instant would silently take in an eighth day.
      def training_load_for(activities, days, zone)
        scored = activities.select(&:tss_score)
        total = scored.sum(&:tss_score)

        acute_cutoff = zone.parse((zone.today - 6).to_s).beginning_of_day
        acute = scored.select { |a| a.started_at >= acute_cutoff }.sum(&:tss_score)
        chronic_weekly = days >= 7 ? (total / (days / 7.0)) : nil

        {
          total_tss: total.round(1),
          average_daily_tss: (total / days.to_f).round(1),
          acute_7d_tss: acute.round(1),
          chronic_weekly_tss: chronic_weekly&.round(1),
          acute_chronic_ratio: ratio(acute, chronic_weekly),
          # Load is understated by exactly this many activities, because the
          # pipeline could not derive a TSS for them.
          activities_missing_tss: activities.size - scored.size,
          sufficient_history_for_chronic_load: sufficient_history?(days, zone),
          history_spans_days: history_span_days(zone)
        }
      end

      # A 28-day window is only a chronic load if 28 days of training actually
      # sit behind it. Asking for a long period does not manufacture history.
      def sufficient_history?(days, zone)
        return false if days < 28

        history_span_days(zone).to_i >= 28
      end

      def history_span_days(zone)
        earliest = Activity.minimum(:started_at)
        return 0 if earliest.nil?

        (zone.today - earliest.in_time_zone(zone).to_date).to_i + 1
      end

      def ratio(acute, chronic_weekly)
        return nil if chronic_weekly.nil? || chronic_weekly.zero?

        (acute / chronic_weekly).round(2)
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

      # Each signal carries the sample size behind it, and each states which
      # direction counts as improvement — pace and decoupling improve downward,
      # efficiency factor improves upward.
      def aerobic_signals_for(activities)
        {
          aerobic_decoupling_pct: mean_with_sample(activities.map(&:aerobic_decoupling_pct))
            .merge(interpretation: "lower is better; under 5% indicates good aerobic conditioning"),
          efficiency_factor: mean_with_sample(activities.map(&:efficiency_factor), precision: 3)
            .merge(interpretation: "higher is better; trends up as fitness improves"),
          average_pace_per_km: mean_with_sample(activities.map(&:average_pace_per_km), precision: 1)
            .merge(unit: "seconds per kilometre", interpretation: "lower is faster"),
          cardiac_drift_bpm: mean_with_sample(activities.map(&:cardiac_drift_bpm), precision: 1)
            .merge(interpretation: "pace is not controlled for, so read alongside terrain and pacing")
        }
      end

      def comparison(current, previous)
        current_distance = current.filter_map(&:distance_meters).sum
        previous_distance = previous.filter_map(&:distance_meters).sum
        current_tss = current.filter_map(&:tss_score).sum
        previous_tss = previous.filter_map(&:tss_score).sum

        {
          note: "Compared against the immediately preceding period of equal length.",
          previous_activity_count: previous.size,
          activity_count_change: current.size - previous.size,
          distance_change_pct: percent_change(previous_distance, current_distance),
          tss_change_pct: percent_change(previous_tss, current_tss),
          # A negative pace delta is faster.
          pace_change_seconds_per_km: pace_delta(current, previous)
        }
      end

      def pace_delta(current, previous)
        now = mean_with_sample(current.map(&:average_pace_per_km), precision: 1)
        before = mean_with_sample(previous.map(&:average_pace_per_km), precision: 1)
        return nil if now[:value].nil? || before[:value].nil?
        return nil if now[:sample_size] < MIN_SAMPLE_FOR_TREND || before[:sample_size] < MIN_SAMPLE_FOR_TREND

        (now[:value] - before[:value]).round(1)
      end

      def notable_signals(current, previous, days, zone)
        signals = []

        if current.empty?
          signals << "No activities recorded in the last #{days} days."
          return signals
        end

        if current.size < MIN_SAMPLE_FOR_TREND
          signals << "Only #{current.size} activities in this period — averages and comparisons are unreliable."
        end

        load = training_load_for(current, days, zone)
        if load[:acute_chronic_ratio]
          if load[:acute_chronic_ratio] > 1.5
            signals << "Acute:chronic load ratio is #{load[:acute_chronic_ratio]}, well above the typical 0.8-1.3 range."
          elsif load[:acute_chronic_ratio] < 0.8
            signals << "Acute:chronic load ratio is #{load[:acute_chronic_ratio]}, below the typical 0.8-1.3 range."
          end
        end

        unless load[:sufficient_history_for_chronic_load]
          signals << if days < 28
            "Period is shorter than 28 days, so the chronic load figure is not a true chronic load."
          else
            "Only #{load[:history_spans_days]} days of history exist, so the chronic load figure is not yet a true chronic load."
          end
        end

        if load[:activities_missing_tss].positive?
          signals << "#{load[:activities_missing_tss]} of #{current.size} activities have no TSS, so training load is understated."
        end

        decoupling = mean_with_sample(current.map(&:aerobic_decoupling_pct))
        if decoupling[:value] && decoupling[:sample_size] >= MIN_SAMPLE_FOR_TREND && decoupling[:value] > 10
          signals << "Average aerobic decoupling is #{decoupling[:value]}%, above the 10% threshold for significant decoupling."
        end

        delta = pace_delta(current, previous)
        if delta && delta.abs >= 5
          direction = delta.negative? ? "faster" : "slower"
          signals << "Average pace is #{delta.abs}s/km #{direction} than the preceding period."
        end

        signals
      end
    end
  end
end
