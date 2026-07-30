module AnalyticalTools
  # Two arbitrary periods side by side, with the differences between them
  # computed rather than left to the client.
  #
  # Calling get_recent_activity_summary twice gets the two halves of this. What
  # it does not get is the delta block or the guard logic around it: suppressing
  # a comparison when one side is too thin to carry it, refusing to compare raw
  # totals across windows of unequal length, and naming an overlap that would
  # otherwise count the same training on both sides.
  #
  # No training_context block. The runner's load state as of today says nothing
  # about the relationship between two historical periods, and attaching it here
  # would invite reading it as belonging to one of them.
  class ComparePeriods < AnalyticalTool
    tool_name "compare_periods"

    description <<~TEXT.strip
      Compares two periods of training directly: volume, terrain, load,
      duration-weighted intensity distribution and aerobic signals for each,
      plus a block of deltas between them. Deltas are period_a relative to
      period_b, so a positive distance delta means period_a covered more. By
      default period_a is the last 28 days and period_b the 28 days before it;
      either can be moved with an explicit end date or an offset in days, and
      given its own length. Prefer the grade-adjusted pace delta over the raw
      one. A delta is suppressed, with the reason named, when either side has too
      few activities carrying the metric or when the periods are of unequal
      length. Returns no verdict on which period was better.
    TEXT

    input_schema(
      properties: {
        period_a_days: {
          type: "integer",
          description: "Length of period A in days. Defaults to 28.",
          minimum: 1,
          maximum: 365
        },
        period_b_days: {
          type: "integer",
          description: "Length of period B in days. Defaults to the same length as period A.",
          minimum: 1,
          maximum: 365
        },
        period_a_end_date: {
          type: "string",
          description: "Last day of period A, as YYYY-MM-DD. Defaults to today."
        },
        period_b_end_date: {
          type: "string",
          description: "Last day of period B, as YYYY-MM-DD. Defaults to the day before period A begins."
        },
        period_a_offset_days: {
          type: "integer",
          description: "Alternative to period_a_end_date: end period A this many days before today.",
          minimum: 0
        },
        period_b_offset_days: {
          type: "integer",
          description: "Alternative to period_b_end_date: end period B this many days before today.",
          minimum: 0
        }
      },
      required: []
    )

    DEFAULT_DAYS = 28

    class << self
      def call(period_a_days: nil, period_b_days: nil, period_a_end_date: nil, period_b_end_date: nil,
               period_a_offset_days: nil, period_b_offset_days: nil, server_context: nil)
        zone = runner_time_zone
        a_days = days_param(period_a_days, default: DEFAULT_DAYS)
        b_days = days_param(period_b_days, default: a_days)

        a_end = resolve_end_date(period_a_end_date, period_a_offset_days, zone.today, zone)
        return a_end if a_end.is_a?(MCP::Tool::Response)

        # Period B defaults to the window immediately preceding A, which is the
        # comparison a client almost always means.
        b_end = resolve_end_date(period_b_end_date, period_b_offset_days, a_end - a_days, zone)
        return b_end if b_end.is_a?(MCP::Tool::Response)

        a = TrainingWindow.ending(a_end, days: a_days, zone: zone)
        b = TrainingWindow.ending(b_end, days: b_days, zone: zone)
        suppressed = {}

        shaped(
          period_a: describe(a),
          period_b: describe(b),
          deltas: deltas(a, b, suppressed),
          comparability: comparability(a, b),
          notable: notable_signals(a, b, suppressed)
        )
      end

      private

      def resolve_end_date(explicit, offset, default, zone)
        return default if explicit.blank? && offset.nil?
        return zone.today - offset.to_i if explicit.blank?

        # strptime rather than parse: Date.parse is lenient enough to read
        # "last tuesday" as a date in the current week, which would silently
        # analyse a period the client never asked for.
        Date.strptime(explicit, "%Y-%m-%d")
      rescue Date::Error
        failure("Could not read #{explicit.inspect} as a date. Use YYYY-MM-DD.")
      end

      def describe(window)
        {
          period: window.period,
          volume: window.volume.merge(distance_km_per_week: distance_km_per_week(window)),
          terrain: window.terrain,
          load: window.load,
          intensity_distribution: window.intensity_distribution,
          aerobic_signals: window.aerobic_signals
        }
      end

      def distance_km_per_week(window)
        (window.total_distance_meters / 1000.0 / window.weeks).round(1)
      end

      # Grade-adjusted pace leads, because it is the delta that survives a change
      # of route. Raw pace follows it so the two can be read against each other:
      # a raw improvement the grade-adjusted figure does not share is a change of
      # terrain, not of fitness.
      def deltas(a, b, suppressed)
        {
          note: "period_a relative to period_b. A negative pace delta means period_a was faster. " \
                "Prefer the grade-adjusted pace delta: it is the one that isolates fitness from terrain.",
          volume_basis: volume_basis(a, b),
          grade_adjusted_pace_change_seconds_per_km:
            mean_delta(a, b, :avg_grade_adjusted_pace_per_km, suppressed, precision: 1),
          pace_change_seconds_per_km: mean_delta(a, b, :average_pace_per_km, suppressed, precision: 1),
          grade_adjusted_efficiency_factor_change:
            mean_delta(a, b, :grade_adjusted_efficiency_factor, suppressed, precision: 3),
          efficiency_factor_change: mean_delta(a, b, :efficiency_factor, suppressed, precision: 3),
          aerobic_decoupling_change_pct_points: mean_delta(a, b, :aerobic_decoupling_pct, suppressed),
          activity_count_change: a.activities.size - b.activities.size,
          weekly_distance_change_pct: percent_change(distance_km_per_week(b), distance_km_per_week(a)),
          weekly_tss_change_pct: percent_change(b.load[:average_weekly_tss], a.load[:average_weekly_tss]),
          total_distance_change_pct: total_delta(a, b, :total_distance_change_pct, suppressed) do
            percent_change(b.total_distance_meters, a.total_distance_meters)
          end,
          total_tss_change_pct: total_delta(a, b, :total_tss_change_pct, suppressed) do
            percent_change(b.total_tss, a.total_tss)
          end,
          elevation_gain_per_km_change_pct: percent_change(b.gain_per_km, a.gain_per_km),
          suppressed: suppressed.presence
        }.compact
      end

      def volume_basis(a, b)
        if a.days == b.days
          "Periods are the same length, so totals and per-week figures are equally comparable."
        else
          "Periods differ in length (#{a.days} vs #{b.days} days). Read the per-week deltas; " \
            "the total-based ones are suppressed, because a raw total over a longer window is larger " \
            "for reasons that have nothing to do with training."
        end
      end

      # Raw totals only mean something across windows of the same length. Rather
      # than emitting a number that reads as a training change when it is really
      # a difference in window size, the total-based deltas drop out and say so.
      def total_delta(a, b, key, suppressed)
        if a.days != b.days
          suppressed[key] = "Suppressed: the periods are #{a.days} and #{b.days} days long, " \
                            "so raw totals are not comparable. Use the per-week figures."
          return nil
        end

        yield
      end

      # A mean is only worth differencing when both sides have enough activities
      # carrying the metric. Suppressed rather than nulled, so the client learns
      # which side was thin instead of guessing why the number is missing.
      def mean_delta(a, b, column, suppressed, precision: 2)
        now = a.mean(column, precision: precision)
        before = b.mean(column, precision: precision)

        thin = []
        thin << "period_a (#{now[:sample_size]})" if now[:sample_size] < TrainingWindow::MIN_SAMPLE_FOR_TREND
        thin << "period_b (#{before[:sample_size]})" if before[:sample_size] < TrainingWindow::MIN_SAMPLE_FOR_TREND

        if thin.any?
          suppressed[column] = "Suppressed: #{thin.to_sentence} carried fewer than " \
                               "#{TrainingWindow::MIN_SAMPLE_FOR_TREND} activities with this metric."
          return nil
        end

        (now[:value] - before[:value]).round(precision)
      end

      def comparability(a, b)
        overlap = overlap_days(a, b)

        {
          equal_length: a.days == b.days,
          overlap_days: overlap,
          # Both periods exclude races from their aerobic averages, so the
          # comparison is training-to-training even when one side contains a race.
          race_efforts: { period_a: a.races.size, period_b: b.races.size },
          note: comparability_note(a, b, overlap)
        }
      end

      def overlap_days(a, b)
        return 0 unless a.overlaps?(b)

        ([ a.to, b.to ].min - [ a.from, b.from ].max).to_i + 1
      end

      def comparability_note(a, b, overlap)
        if overlap.positive?
          "The periods overlap by #{overlap} #{'day'.pluralize(overlap)}, " \
            "so that training is counted on both sides of every delta."
        elsif (a.from - b.to).to_i == 1 || (b.from - a.to).to_i == 1
          "Periods are adjacent."
        else
          "Periods are disjoint."
        end
      end

      def notable_signals(a, b, suppressed)
        signals = []

        [ [ "period_a", a ], [ "period_b", b ] ].each do |name, window|
          if window.empty?
            signals << "#{name} (#{window.from} to #{window.to}) contains no activities, " \
                       "so every delta against it is meaningless."
          elsif window.activities.size < TrainingWindow::MIN_SAMPLE_FOR_TREND
            signals << "#{name} contains only #{window.activities.size} " \
                       "#{'activity'.pluralize(window.activities.size)}."
          end
        end

        overlap = overlap_days(a, b)
        if overlap.positive?
          signals << "The two periods overlap by #{overlap} #{'day'.pluralize(overlap)}. " \
                     "Comparing overlapping periods is usually unintentional — the shared training " \
                     "pulls both sides toward each other and damps every delta."
        end

        if a.days != b.days
          signals << "Periods are of unequal length (#{a.days} vs #{b.days} days). " \
                     "Volume and load are compared per week; the total-based deltas are suppressed."
        end

        signals.concat(divergence_signals(a, b, suppressed))
        signals
      end

      # The finding worth surfacing is the disagreement between the two pace
      # figures. Raw pace improving while the grade-adjusted figure holds flat
      # means the routes got easier between the periods.
      def divergence_signals(a, b, suppressed)
        raw = mean_delta(a, b, :average_pace_per_km, {}, precision: 1)
        adjusted = mean_delta(a, b, :avg_grade_adjusted_pace_per_km, {}, precision: 1)
        signals = []

        if raw && adjusted && (raw - adjusted).abs >= 5
          signals << "Raw and grade-adjusted pace deltas disagree by #{(raw - adjusted).abs.round(1)}s/km, " \
                     "so the terrain differed between the periods. The grade-adjusted figure is the one " \
                     "to read."
        end

        if suppressed.any?
          signals << "#{suppressed.size} #{'delta'.pluralize(suppressed.size)} suppressed rather than " \
                     "reported as null — see the suppressed block for which and why."
        end

        signals
      end
    end
  end
end
