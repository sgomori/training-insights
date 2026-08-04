module AnalyticalTools
  # The inputs to the decision about the next run. Never the decision.
  #
  # The name is in the agreed tool inventory and stays, but V1_SCOPE.md is
  # explicit that this is not a coaching service: tools return shaped analytical
  # data and do not prescribe training. So this tool assembles what a coach would
  # want in front of them — how long since the last run and how hard it was, what
  # the recovery markers say against their own baselines, how the recent intensity
  # split compares with the 80/20 convention, how much load is available before
  # the acute:chronic ratio crosses a given threshold, and what race is coming —
  # and stops there.
  #
  # Load headroom is the calculation that earns the tool its place. Given the
  # current acute and chronic load, solving for the additional TSS that would put
  # the ratio at a threshold is arithmetic over load state. It is not advice, and
  # the response does not say which threshold to aim at.
  class SuggestNextRun < AnalyticalTool
    tool_name "suggest_next_run"

    description <<~TEXT.strip
      Assembles the inputs to a decision about the next run and returns them
      without making the decision. Carries the current load state, the last
      activity and how long ago it was, recovery markers measured against their
      own trailing baselines, the recent easy-versus-hard split against the 80/20
      convention, how much additional training load is available before the
      acute:chronic ratio would cross 1.3 or 1.5, and the next race with its goal
      pace. Optionally contextualises a planned distance against recent training.
      This tool prescribes nothing: it returns figures and reference bands, and
      the caller decides what to do with them.
    TEXT

    input_schema(
      properties: {
        planned_distance_km: {
          type: "number",
          description: "A distance under consideration, to be contextualised against recent training " \
                       "and the next race. Nothing is prescribed either way.",
          minimum: 0.1
        }
      },
      required: []
    )

    # Zones 1 and 2 are the easy end of the five-zone heart rate model.
    EASY_HR_ZONES = %w[zone_1 zone_2].freeze

    # The polarised-training convention: roughly 80% of time easy, 20% hard.
    EASY_TARGET_PCT = 80.0

    # Thresholds the headroom is solved for. Both are conventional reference
    # points rather than recommendations, and the response says so.
    ACWR_THRESHOLDS = [ 1.3, 1.5 ].freeze

    # Trailing days a recovery reading is compared against.
    BASELINE_DAYS = 28

    # Below this many preceding readings a baseline is too thin to quote a
    # standard-deviation figure against as though it meant something.
    MIN_BASELINE_READINGS = 7

    # A recovery reading older than this is history rather than a recovery
    # indicator, and the response says how old every reading is.
    STALE_READING_DAYS = 3

    RECOVERY_METRICS = {
      hrv: { column: :hrv_ms, metric: :hrv_ms, precision: 1 },
      resting_hr: { column: :resting_hr_bpm, metric: :resting_hr_bpm, precision: 1 },
      sleep: { column: :sleep_score, metric: :sleep_score, precision: 1 }
    }.freeze

    class << self
      def call(planned_distance_km: nil, server_context: nil)
        zone = runner_time_zone
        context = TrainingContext.current(zone: zone)
        recent = TrainingWindow.ending(zone.today, days: TrainingContext::CHRONIC_DAYS, zone: zone)

        payload = {
          purpose: "Inputs to a decision about the next run. This tool does not prescribe training: " \
                   "it returns load state, recovery markers and load headroom, and leaves the judgement " \
                   "to the caller.",
          training_context: context.to_h,
          last_activity: last_activity(zone),
          recovery_indicators: recovery_indicators(zone),
          intensity_balance: intensity_balance(zone),
          load_headroom: load_headroom(context),
          race_proximity: race_proximity(zone),
          notable: []
        }

        payload[:planned_run] = planned_run(planned_distance_km, recent, zone) if planned_distance_km.present?
        payload[:notable] = notable_signals(payload, context, recent)

        shaped(payload)
      end

      private

      def last_activity(zone)
        activity = Activity.most_recent_first.includes(:race).first
        return { note: "No activities have been recorded, so there is no training to read against." } if activity.nil?

        date = activity.started_at.in_time_zone(zone).to_date

        {
          date: date.to_s,
          days_ago: (zone.today - date).to_i,
          activity_type: activity.activity_type,
          distance_km: activity.distance_meters ? (activity.distance_meters / 1000.0).round(2) : nil,
          duration_seconds: activity.duration_seconds&.round,
          tss_score: activity.tss_score&.round(1),
          average_pace_per_km: activity.average_pace_per_km&.round(1),
          pace_cv: MetricInterpretation.describe(:pace_cv, value: activity.pace_cv&.round(3)),
          aerobic_decoupling_pct: MetricInterpretation.describe(
            :aerobic_decoupling_pct, value: activity.aerobic_decoupling_pct&.round(1)
          ),
          was_a_race: activity.race?,
          race_name: activity.race&.name
        }.compact
      end

      # Each reading against the mean of the preceding 28 days, with the
      # deviation in both absolute terms and standard deviations. HRV especially
      # is only readable against a personal baseline, which is why the baseline
      # travels with the value rather than being left for the client to assemble.
      def recovery_indicators(zone)
        present = RECOVERY_METRICS.filter_map do |type, config|
          latest = HealthMetric.of_type(type.to_s).where.not(config[:column] => nil)
            .order(recorded_date: :desc).first
          [ type, config, latest ] if latest
        end

        if present.empty?
          return {
            available: false,
            missing_metric_types: RECOVERY_METRICS.keys.map(&:to_s),
            note: "No recovery data is available: the health metric types " \
                  "#{RECOVERY_METRICS.keys.map(&:to_s).to_sentence} have no readings. Recovery data is " \
                  "recorded separately from activities, so its absence says nothing about the runner's " \
                  "training or recovery. Every other section of this response is unaffected."
          }
        end

        indicators = { available: true }
        missing = RECOVERY_METRICS.keys.map(&:to_s) - present.map { |type, _config, _latest| type.to_s }
        indicators[:missing_metric_types] = missing if missing.any?

        present.each do |type, config, latest|
          indicators[type] = reading(latest, config, zone)
        end

        indicators
      end

      def reading(latest, config, zone)
        value = latest.public_send(config[:column]).to_f
        history = HealthMetric.of_type(latest.metric_type)
          .where(recorded_date: (latest.recorded_date - BASELINE_DAYS)...latest.recorded_date)
          .where.not(config[:column] => nil)
          .pluck(config[:column])
          .map(&:to_f)

        baseline = mean_with_sample(history, precision: config[:precision])
        deviation = baseline[:value] ? (value - baseline[:value]).round(config[:precision]) : nil
        spread = standard_deviation(history)

        MetricInterpretation.describe(
          config[:metric], value: value.round(config[:precision]), caveats: reading_caveats(latest, baseline, zone)
        ).merge(
          recorded_date: latest.recorded_date.to_s,
          days_old: (zone.today - latest.recorded_date).to_i,
          baseline: baseline[:value],
          baseline_days: BASELINE_DAYS,
          baseline_sample_size: baseline[:sample_size],
          deviation_from_baseline: deviation,
          deviation_in_standard_deviations: (deviation && spread&.positive? ? (deviation / spread).round(2) : nil)
        ).compact
      end

      def reading_caveats(latest, baseline, zone)
        caveats = []
        age = (zone.today - latest.recorded_date).to_i

        if age > STALE_READING_DAYS
          caveats << "This reading is #{age} days old. A stale value describes the day it was taken, " \
                     "not the runner's current state."
        end

        if baseline[:sample_size].zero?
          caveats << "No preceding readings, so there is no baseline to compare against. " \
                     "This metric is not interpretable from a single value."
        elsif baseline[:sample_size] < MIN_BASELINE_READINGS
          caveats << "Baseline rests on only #{baseline[:sample_size]} preceding " \
                     "#{'reading'.pluralize(baseline[:sample_size])}, too few to read a " \
                     "standard-deviation figure from."
        end

        caveats
      end

      def intensity_balance(zone)
        {
          basis: "Duration-weighted share of time in heart rate zones 1 and 2. The 80/20 convention holds " \
                 "that roughly #{EASY_TARGET_PCT.to_i}% of training time should be easy; the deviation is " \
                 "reported, not judged. Mapping zones 1 and 2 onto \"easy\" assumes zone 2 tops out near " \
                 "the first lactate threshold, which holds for percent-of-threshold zone boundaries but " \
                 "not necessarily for fixed-BPM ones.",
          last_7d: easy_share(TrainingWindow.ending(zone.today, days: 7, zone: zone)),
          last_28d: easy_share(TrainingWindow.ending(zone.today, days: 28, zone: zone))
        }
      end

      def easy_share(window)
        zones = window.zones(:hr_zone_distribution)

        if zones[:zones].nil?
          return {
            easy_pct: nil,
            activities_contributing: 0,
            note: "No activity in this window carries a heart rate zone distribution, " \
                  "so the split cannot be computed."
          }
        end

        easy = EASY_HR_ZONES.sum { |zone_name| zones[:zones][zone_name].to_f }.round(1)

        {
          easy_pct: easy,
          harder_than_easy_pct: (100.0 - easy).round(1),
          deviation_from_80_20: (easy - EASY_TARGET_PCT).round(1),
          activities_contributing: zones[:activities_contributing],
          hours_contributing: zones[:hours_contributing]
        }
      end

      # How much additional load fits before the acute:chronic ratio reaches a
      # threshold. Solved rather than approximated: load added today lands in both
      # the acute window and the chronic one, so
      #
      #   (acute + x) / ((chronic_total + x) / 4) = threshold
      #
      # which rearranges to x = (threshold * chronic_total - 4 * acute) / (4 - threshold).
      # Holding the chronic baseline fixed would understate the headroom, because
      # the added load raises the denominator as well as the numerator.
      def load_headroom(context)
        acute = context.acute_tss
        chronic_weekly = context.chronic_weekly_tss

        if chronic_weekly.nil? || chronic_weekly.zero?
          return {
            basis: "No load in the last #{TrainingContext::CHRONIC_DAYS} days, so there is no chronic " \
                   "baseline to compute headroom against. Any ratio would be a division by zero.",
            current_acute_7d_tss: acute.round(1)
          }
        end

        # Derived from CHRONIC_DAYS rather than hard-coded, so the algebra below
        # cannot silently disagree with TrainingContext if the window changes.
        weeks_in_chronic = TrainingContext::CHRONIC_DAYS / 7.0
        chronic_total = chronic_weekly * weeks_in_chronic

        {
          basis: "Additional TSS that would put the acute:chronic ratio at each threshold if it were run " \
                 "today. Accounts for the load also entering the chronic baseline. The thresholds are " \
                 "conventional reference points, not recommendations.",
          current_acute_7d_tss: acute.round(1),
          chronic_weekly_tss: chronic_weekly.round(1),
          current_ratio: context.acute_chronic_ratio,
          additional_tss_to_reach: ACWR_THRESHOLDS.map do |threshold|
            headroom = ((threshold * chronic_total) - (weeks_in_chronic * acute)) /
                       (weeks_in_chronic - threshold)

            {
              ratio_threshold: threshold,
              additional_tss: headroom.positive? ? headroom.round(1) : 0.0,
              note: ("The ratio is already at or above this threshold." unless headroom.positive?)
            }.compact
          end
        }
      end

      def race_proximity(zone)
        race = Race.next_race
        return nil if race.nil?

        {
          name: race.name,
          date: race.race_date.to_s,
          days_until: race.days_until,
          distance_km: (race.distance_meters / 1000.0).round(1),
          target_pace_per_km: race.target_pace_per_km,
          note: ("No target time is set, so there is no goal pace to contextualise against." if race.target_time_seconds.nil?)
        }.compact
      end

      # A planned distance placed against what the runner has actually been
      # doing. No verdict on whether to run it.
      def planned_run(planned_distance_km, recent, zone)
        planned = planned_distance_km.to_f
        volume = recent.volume
        race = Race.next_race

        {
          distance_km: planned.round(2),
          descriptive_band: DistanceBucket.describe(planned * 1000)&.key,
          vs_average_of_last_28d_pct: percent_change(volume[:average_distance_km], planned),
          vs_longest_of_last_28d_pct: percent_change(volume[:longest_run_km], planned),
          pct_of_next_race_distance: race ? ((planned / (race.distance_meters / 1000.0)) * 100).round(1) : nil,
          basis: "The planned distance against the last #{recent.days} days of training. " \
                 "Context only — this tool does not say whether to run it."
        }.compact
      end

      def notable_signals(payload, context, recent)
        signals = []

        signals.concat(rest_signals(payload, context))
        signals.concat(recovery_signals(payload))
        signals.concat(balance_signals(payload))
        signals.concat(load_signals(payload, context))

        missing = recent.load[:activities_missing_tss]
        if missing.positive?
          signals << "#{missing} #{'activity'.pluralize(missing)} in the last #{recent.days} days " \
                     "#{missing == 1 ? 'has' : 'have'} no TSS, so both the ratio and the headroom are " \
                     "computed on an understated load."
        end

        signals
      end

      def rest_signals(payload, context)
        last = payload[:last_activity]
        return [ "No activities have been recorded." ] if last[:date].nil?

        signals = []
        days_ago = last[:days_ago]

        if days_ago.zero?
          signals << "The last activity was today#{last[:was_a_race] ? ', and it was a race' : ''}."
        elsif days_ago >= 7
          signals << "The last activity was #{days_ago} days ago, so the acute load figure describes a " \
                     "period that has largely emptied."
        end

        streak = context.consecutive_training_days
        if streak >= 7 && days_ago.zero?
          signals << "#{streak} consecutive training days with no rest day."
        end

        if context.days_since_last_race && context.days_since_last_race <= 14
          signals << "A race was run #{context.days_since_last_race} days ago. The fortnight after a race " \
                     "is suppressed for reasons unrelated to fitness."
        end

        signals
      end

      def recovery_signals(payload)
        recovery = payload[:recovery_indicators]
        return [ recovery[:note] ] unless recovery[:available]

        signals = []

        if recovery[:missing_metric_types].present?
          signals << "No readings for #{recovery[:missing_metric_types].to_sentence}."
        end

        RECOVERY_METRICS.each_key do |type|
          reading = recovery[type]
          next if reading.nil?

          sds = reading[:deviation_in_standard_deviations]
          # Gated on a baseline thick enough to carry a spread. Quoting "2.9
          # standard deviations below baseline" off three readings reads as a
          # finding when it is an artefact of the sample.
          if sds && sds.abs >= 1.5 && reading[:baseline_sample_size].to_i >= MIN_BASELINE_READINGS
            direction = sds.negative? ? "below" : "above"
            signals << "#{type} is #{sds.abs} standard deviations #{direction} its " \
                       "#{BASELINE_DAYS}-day baseline (#{reading[:value]} against #{reading[:baseline]})."
          end

          if reading[:days_old] > STALE_READING_DAYS
            signals << "The most recent #{type} reading is #{reading[:days_old]} days old."
          end
        end

        signals
      end

      def balance_signals(payload)
        recent = payload.dig(:intensity_balance, :last_28d)
        return [] if recent.nil? || recent[:easy_pct].nil?

        deviation = recent[:deviation_from_80_20]
        return [] if deviation.nil? || deviation.abs < 10

        if deviation.negative?
          [ "Only #{recent[:easy_pct]}% of the last 28 days was spent in zones 1-2, " \
            "against the #{EASY_TARGET_PCT.to_i}% of the 80/20 convention." ]
        else
          [ "#{recent[:easy_pct]}% of the last 28 days was spent in zones 1-2, " \
            "above the #{EASY_TARGET_PCT.to_i}% of the 80/20 convention." ]
        end
      end

      def load_signals(payload, context)
        headroom = payload[:load_headroom]
        return [ headroom[:basis] ] if headroom[:additional_tss_to_reach].nil?

        signals = []
        ratio = context.acute_chronic_ratio

        if ratio && ratio > ACWR_THRESHOLDS.max
          signals << "The acute:chronic ratio is already #{ratio}, above both thresholds, " \
                     "so the solved headroom is zero at each."
        end

        unless context.sufficient_history_for_chronic_load?
          signals << "Only #{context.history_spans_days} days of history exist, so the chronic baseline " \
                     "the headroom is solved against is not yet a true chronic load."
        end

        signals
      end
    end
  end
end
