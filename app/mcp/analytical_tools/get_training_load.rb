module AnalyticalTools
  # Training load over time: how much, distributed how evenly, and changing how
  # fast. Where get_recent_activity_summary reports one period's totals, this
  # tool reports the shape of the block that produced them.
  #
  # Three derived figures carry the analysis. Ramp rate says how fast load is
  # being added. Monotony says whether it arrived as a varied week or seven
  # identical days. Strain combines the two, because the same weekly total is a
  # different stress depending on how it was spread.
  class GetTrainingLoad < AnalyticalTool
    tool_name "get_training_load"

    description <<~TEXT.strip
      Training load broken down by week, with the derived figures that describe
      how the load was accumulated: week-over-week ramp rate, Foster's training
      monotony, and training strain. Use it to see whether volume is rising,
      falling or flat, and whether the weeks were varied or uniform. Weekly
      totals, the load's distribution across the days of each week, and the
      runner's current load state all come back in one response. Partial weeks at
      the window edges are reported as such rather than compared against full
      ones.
    TEXT

    input_schema(
      properties: {
        days: {
          type: "integer",
          description: "Length of the window to analyse, counting back from today. Defaults to 42 (six weeks).",
          minimum: 7,
          maximum: 365
        }
      },
      required: []
    )

    DEFAULT_DAYS = 42
    MIN_DAYS = 7

    # Two complete weeks is the floor for any week-over-week figure: one week
    # gives nothing to compare against.
    MIN_WEEKS_FOR_RAMP = 2

    # Conventional guidance treats a sustained weekly increase past this as an
    # aggressive build. The threshold is surfaced as a signal; whether it is a
    # problem is the client's call.
    NOTABLE_RAMP_RATE_PCT = 10.0

    NOTABLE_MONOTONY = 2.0

    class << self
      def call(days: nil, server_context: nil)
        days = days_param(days, default: DEFAULT_DAYS, min: MIN_DAYS)
        zone = runner_time_zone
        window = TrainingWindow.ending(zone.today, days: days, zone: zone)
        buckets = window.weekly_buckets
        complete = buckets.select(&:complete?)

        shaped(
          period: window.period,
          training_context: TrainingContext.current(zone: zone).to_h,
          load: window.load,
          weekly_breakdown: weekly_breakdown(buckets),
          ramp_rate: ramp_rate(complete, buckets.size),
          monotony: monotony_summary(complete),
          strain: strain_summary(complete),
          notable: notable_signals(window, buckets, complete)
        )
      end

      private

      # Each week carries its own monotony and strain, because both are weekly
      # measures by definition and a block average hides the week that was
      # unusual. The week-over-week change is only emitted between two complete
      # weeks: a partial edge week holds less than seven days of training, so
      # comparing against it would report the window boundary as a training
      # change.
      def weekly_breakdown(buckets)
        buckets.each_with_index.map do |bucket, index|
          previous = index.positive? ? buckets[index - 1] : nil

          # Nulls are kept rather than compacted away: every row in this list
          # carries the same keys, so a client can scan the weeks without
          # checking which fields a given week happens to have. complete_week
          # says why a row's derived figures are absent.
          bucket.to_h.merge(
            change_from_previous_pct: week_over_week_change(previous, bucket),
            monotony: monotony_for(bucket),
            strain: strain_for(bucket),
            activities_missing_tss: bucket.activities_missing_tss
          )
        end
      end

      def week_over_week_change(previous, bucket)
        return nil if previous.nil?
        return nil unless previous.complete? && bucket.complete?

        percent_change(previous.tss, bucket.tss)
      end

      # Mean week-over-week percentage change across complete weeks. A week of
      # zero load has no defined percentage change from it, so those transitions
      # drop out of the mean rather than being counted as no change.
      def ramp_rate(complete, total_weeks)
        changes = complete.each_cons(2).filter_map { |previous, week| percent_change(previous.tss, week.tss) }

        MetricInterpretation.describe(
          :weekly_ramp_rate_pct,
          **mean_with_sample(changes),
          caveats: ramp_caveats(complete, total_weeks, changes)
        )
      end

      def ramp_caveats(complete, total_weeks, changes)
        caveats = [ "Computed over the #{complete.size} complete #{'week'.pluralize(complete.size)} " \
                    "of the #{total_weeks} in the window." ]

        if complete.size < MIN_WEEKS_FOR_RAMP
          caveats << "Fewer than #{MIN_WEEKS_FOR_RAMP} complete weeks, so there is no week-over-week change to report."
        end

        skipped = [ complete.size - 1, 0 ].max - changes.size
        if skipped.positive?
          caveats << "#{skipped} #{'transition'.pluralize(skipped)} skipped because the preceding week " \
                     "carried no load, which has no defined percentage change."
        end

        caveats
      end

      def monotony_summary(complete)
        values = complete.map { |bucket| monotony_for(bucket) }

        MetricInterpretation.describe(
          :training_monotony,
          **mean_with_sample(values),
          caveats: weekly_measure_caveats(complete, values, "monotony")
        )
      end

      def strain_summary(complete)
        values = complete.map { |bucket| strain_for(bucket) }

        MetricInterpretation.describe(
          :training_strain,
          **mean_with_sample(values, precision: 0),
          caveats: weekly_measure_caveats(complete, values, "strain")
        )
      end

      def weekly_measure_caveats(complete, values, name)
        caveats = [ "Averaged across complete weeks. Each week's own #{name} is in weekly_breakdown; " \
                    "a block average hides the week that was unusual." ]

        undefined = complete.size - values.compact.size
        if undefined.positive?
          caveats << "#{undefined} complete #{'week'.pluralize(undefined)} produced no #{name}, " \
                     "because the daily load did not vary enough to divide by."
        end

        caveats
      end

      # Foster's monotony: mean daily load divided by the standard deviation of
      # daily load across the week.
      #
      # Rest days count as zero here, which inverts the rule that holds
      # everywhere else in this codebase. It is deliberate. A day with no run
      # genuinely carries no load, and that is a different fact from an activity
      # whose tss_score is nil because a stream was missing. Monotony is defined
      # over the seven days of the week, so dropping the rest days would compute
      # the spread over the wrong population and report a hard week as a varied
      # one. TrainingWindow::WeeklyBucket#daily_tss is where the zeroes are
      # introduced.
      #
      # Nil rather than infinity when the spread is zero — a week of seven
      # identical days, or a week with no training at all. Both are real, and
      # neither has a defined monotony.
      def monotony_for(bucket)
        return nil unless bucket.complete?

        daily = bucket.daily_tss
        deviation = standard_deviation(daily)
        return nil if deviation.nil? || deviation.zero?

        ((daily.sum / daily.size) / deviation).round(2)
      end

      def strain_for(bucket)
        monotony = monotony_for(bucket)
        return nil if monotony.nil?

        (bucket.tss * monotony).round
      end

      def notable_signals(window, buckets, complete)
        signals = []

        if window.empty?
          signals << "No activities recorded in the last #{window.days} days."
          return signals
        end

        signals.concat(coverage_signals(buckets, complete))
        signals.concat(ramp_signals(complete))
        signals.concat(monotony_signals(complete))

        rest_weeks = complete.select { |bucket| bucket.activity_count.zero? }
        if rest_weeks.any?
          signals << "#{rest_weeks.size} complete #{'week'.pluralize(rest_weeks.size)} with no training at all " \
                     "(#{rest_weeks.map { |b| b.week_start.to_s }.join(', ')})."
        end

        missing = window.load[:activities_missing_tss]
        if missing.positive?
          signals << "#{missing} #{'activity'.pluralize(missing)} in the window #{missing == 1 ? 'has' : 'have'} " \
                     "no TSS, so every load figure here is understated."
        end

        signals
      end

      def coverage_signals(buckets, complete)
        partial = buckets.reject(&:complete?)
        signals = []

        if partial.any?
          signals << "#{partial.size} of #{buckets.size} weeks fall only partly inside the window " \
                     "and are excluded from the ramp rate, monotony and strain figures. " \
                     "Request a multiple of 7 days aligned to a Monday for whole weeks throughout."
        end

        if complete.size < MIN_WEEKS_FOR_RAMP
          signals << "Only #{complete.size} complete #{'week'.pluralize(complete.size)} in the window, " \
                     "so there is not enough to describe a trend."
        end

        signals
      end

      def ramp_signals(complete)
        changes = complete.each_cons(2).filter_map { |previous, week| percent_change(previous.tss, week.tss) }
        return [] if changes.empty?

        signals = []
        mean = mean_with_sample(changes)[:value]

        if mean && mean > NOTABLE_RAMP_RATE_PCT
          signals << "Weekly load is rising by #{mean}% a week on average, " \
                     "above the #{NOTABLE_RAMP_RATE_PCT.to_i}% conventionally treated as an aggressive build."
        end

        consecutive = longest_run_of_builds(changes)
        if consecutive >= 3
          signals << "#{consecutive} consecutive weeks of load increase above " \
                     "#{NOTABLE_RAMP_RATE_PCT.to_i}%, which is the pattern the guidance is about " \
                     "rather than any single week."
        end

        signals
      end

      def longest_run_of_builds(changes)
        longest = 0
        current = 0
        changes.each do |change|
          current = change > NOTABLE_RAMP_RATE_PCT ? current + 1 : 0
          longest = [ longest, current ].max
        end
        longest
      end

      def monotony_signals(complete)
        monotonous = complete.filter_map do |bucket|
          value = monotony_for(bucket)
          [ bucket, value ] if value && value >= NOTABLE_MONOTONY
        end
        return [] if monotonous.empty?

        monotonous.map do |bucket, value|
          "Week of #{bucket.week_start} had a monotony of #{value} across #{bucket.activity_count} " \
            "#{'activity'.pluralize(bucket.activity_count)} and #{bucket.tss} TSS — the load arrived in " \
            "near-identical daily doses rather than as hard and easy days."
        end
      end
    end
  end
end
