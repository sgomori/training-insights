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
        # Whole *and* finished. A week still being run is not comparable with the
        # weeks before it, and on the last day of a week it would otherwise pass
        # the whole-week test with the day's training still ahead of it.
        comparable = buckets.select(&:comparable?)

        shaped(
          period: window.period,
          training_context: TrainingContext.current(zone: zone).to_h,
          load: window.load,
          weekly_breakdown: weekly_breakdown(buckets),
          ramp_rate: ramp_rate(comparable, buckets.size),
          monotony: monotony_summary(comparable),
          strain: strain_summary(comparable),
          notable: notable_signals(window, buckets, comparable)
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
        return nil unless previous.comparable? && bucket.comparable?

        percent_change(previous.tss, bucket.tss)
      end

      # The compound weekly growth rate across the window, not the mean of the
      # week-over-week percentage changes.
      #
      # The mean of ratios is not a rate of growth, and it is biased upward by
      # exactly the week-to-week variability a well-structured block has. Weekly
      # loads of 200, 300, 200, 300 produce changes of +50%, -33%, +50% — a mean
      # of +22% a week, which would trip the aggressive-build signal — across a
      # block whose net change is zero. The compound rate reports 0%, which is
      # what happened. The 10% convention this is banded against is a
      # compound-growth figure, so it is the compound rate that belongs beside it.
      #
      # The individual transitions are still in weekly_breakdown, where a client
      # reading a single step-up week can find it.
      def ramp_rate(comparable, total_weeks)
        changes = comparable.each_cons(2).filter_map { |previous, week| percent_change(previous.tss, week.tss) }

        MetricInterpretation.describe(
          :weekly_ramp_rate_pct,
          value: compound_weekly_rate(comparable),
          sample_size: comparable.size,
          caveats: ramp_caveats(comparable, total_weeks, changes)
        ).merge(mean_of_weekly_changes_pct: mean_with_sample(changes, precision: 1)[:value])
      end

      # (last / first) ** (1 / periods) - 1, over the weeks that bound the window.
      # Undefined from a zero-load first week, and from a single week.
      def compound_weekly_rate(comparable)
        return nil if comparable.size < MIN_WEEKS_FOR_RAMP

        first = comparable.first.tss
        last = comparable.last.tss
        return nil unless first.positive?

        periods = comparable.size - 1
        ((((last / first)**(1.0 / periods)) - 1) * 100).round(1)
      end

      def ramp_caveats(comparable, total_weeks, changes)
        caveats = [ "Compound weekly growth rate across the #{comparable.size} " \
                    "#{'week'.pluralize(comparable.size)} of the #{total_weeks} in the window that are both " \
                    "whole and finished. mean_of_weekly_changes_pct is the arithmetic mean of the " \
                    "week-over-week changes beside it; it runs higher than the compound rate whenever the " \
                    "weeks vary, and is not a growth rate." ]

        if comparable.size < MIN_WEEKS_FOR_RAMP
          caveats << "Fewer than #{MIN_WEEKS_FOR_RAMP} whole finished weeks, " \
                     "so there is no week-over-week change to report."
        elsif !comparable.first.tss.positive?
          caveats << "The first week of the window carried no load, so a compound rate from it is undefined."
        end

        skipped = [ comparable.size - 1, 0 ].max - changes.size
        if skipped.positive?
          caveats << "#{skipped} #{'transition'.pluralize(skipped)} excluded from the arithmetic mean because " \
                     "the preceding week carried no load, which has no defined percentage change."
        end

        caveats
      end

      def monotony_summary(comparable)
        values = comparable.map { |bucket| monotony_for(bucket) }

        MetricInterpretation.describe(
          :training_monotony,
          **mean_with_sample(values),
          caveats: weekly_measure_caveats(comparable, values, "monotony")
        )
      end

      def strain_summary(comparable)
        values = comparable.map { |bucket| strain_for(bucket) }

        MetricInterpretation.describe(
          :training_strain,
          **mean_with_sample(values, precision: 0),
          caveats: weekly_measure_caveats(comparable, values, "strain")
        )
      end

      # Names each reason a week produced no figure separately. "The load did not
      # vary" and "a session could not be scored" are opposite facts about a week,
      # and a single caveat covering both tells a client nothing.
      def weekly_measure_caveats(comparable, values, name)
        caveats = [ "Averaged across whole finished weeks. Each week's own #{name} is in weekly_breakdown; " \
                    "a block average hides the week that was unusual." ]

        unscored = comparable.count { |bucket| bucket.activities_missing_tss.positive? }
        if unscored.positive?
          caveats << "#{unscored} #{'week'.pluralize(unscored)} produced no #{name} because a session in " \
                     "#{unscored == 1 ? 'it' : 'them'} carries no TSS. Counting an unscored training day as " \
                     "zero would put it in the week as a rest day and move the figure by a whole band."
        end

        flat = comparable.count do |bucket|
          bucket.activities_missing_tss.zero? && bucket.activity_count.positive? && monotony_for(bucket).nil?
        end
        if flat.positive?
          caveats << "#{flat} #{'week'.pluralize(flat)} produced no #{name} because the daily load did not " \
                     "vary at all, leaving nothing to divide by."
        end

        rest = comparable.count { |bucket| bucket.activity_count.zero? }
        if rest.positive?
          caveats << "#{rest} #{'week'.pluralize(rest)} carried no training at all, which has no defined #{name}."
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
      #
      # Also nil when any day of the week was trained but could not be scored.
      # There is no honest way to place such a day in the population: dropping it
      # computes the spread over six days, and zeroing it enters a training day as
      # a rest day, which moves monotony by a whole band. The caveat says which
      # weeks were withheld and why.
      def monotony_for(bucket)
        return nil unless bucket.comparable?
        return nil if bucket.activities_missing_tss.positive?

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

      def notable_signals(window, buckets, comparable)
        signals = []

        if window.empty?
          signals << "No activities recorded in the last #{window.days} days."
          return signals
        end

        signals.concat(coverage_signals(buckets, comparable))
        signals.concat(ramp_signals(comparable))
        signals.concat(monotony_signals(comparable))

        rest_weeks = comparable.select { |bucket| bucket.activity_count.zero? }
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

      def coverage_signals(buckets, comparable)
        partial = buckets.reject(&:complete?)
        in_progress = buckets.select { |bucket| bucket.complete? && bucket.in_progress? }
        signals = []

        if partial.any?
          signals << "#{partial.size} of #{buckets.size} weeks fall only partly inside the window " \
                     "and are excluded from the ramp rate, monotony and strain figures. " \
                     "Request a multiple of 7 days aligned to a Monday for whole weeks throughout."
        end

        if in_progress.any?
          signals << "The week of #{in_progress.first.week_start} is still being run, so it is excluded from " \
                     "the derived figures even though all seven of its days fall inside the window. " \
                     "Comparing a week in progress against finished ones reads the calendar as a taper."
        end

        if comparable.size < MIN_WEEKS_FOR_RAMP
          signals << "Only #{comparable.size} whole finished #{'week'.pluralize(comparable.size)} in the window, " \
                     "so there is not enough to describe a trend."
        end

        signals
      end

      def ramp_signals(comparable)
        return [] if comparable.size < MIN_WEEKS_FOR_RAMP

        signals = []
        rate = compound_weekly_rate(comparable)

        if rate && rate > NOTABLE_RAMP_RATE_PCT
          signals << "Weekly load is compounding at #{rate}% a week across #{comparable.size} weeks, " \
                     "above the #{NOTABLE_RAMP_RATE_PCT.to_i}% conventionally treated as an aggressive build."
        end

        consecutive = longest_run_of_builds(comparable)
        if consecutive >= 3
          signals << "#{consecutive} consecutive weeks of load increase above " \
                     "#{NOTABLE_RAMP_RATE_PCT.to_i}%, which is the pattern the guidance is about " \
                     "rather than any single week."
        end

        signals
      end

      # Walks the week pairs rather than a compacted list of changes, so a
      # transition out of a zero-load week breaks the run instead of collapsing
      # and letting two non-adjacent builds count as consecutive.
      def longest_run_of_builds(comparable)
        longest = 0
        current = 0

        comparable.each_cons(2) do |previous, week|
          change = percent_change(previous.tss, week.tss)
          current = change && change > NOTABLE_RAMP_RATE_PCT ? current + 1 : 0
          longest = [ longest, current ].max
        end

        longest
      end

      def monotony_signals(comparable)
        monotonous = comparable.filter_map do |bucket|
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
