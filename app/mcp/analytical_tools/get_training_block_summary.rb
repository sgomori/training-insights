module AnalyticalTools
  # A named span of training, summarised. Where get_recent_activity_summary
  # always looks back from today, this tool takes explicit dates, so a completed
  # block can be reviewed long after it ended.
  #
  # The design work here is key-workout detection. "Which were the hard sessions"
  # is the question clients actually ask, and the answer has to be defined rather
  # than felt. Five rules qualify a session, each named in the response, so a
  # client asking about long runs and one asking about intervals can both answer
  # from the same output.
  class GetTrainingBlockSummary < AnalyticalTool
    tool_name "get_training_block_summary"

    description <<~TEXT.strip
      Summarises a training block between two explicit dates, or the last N days
      as a convenience: volume, terrain, load, intensity distribution, aerobic
      signals, a week-by-week breakdown, the peak week and the longest run. Also
      identifies the block's key workouts and states which rule qualified each
      one — longest run of its week, top-quartile load, time above heart rate
      zone 4, structured pacing, or a race effort. Use it to review a completed
      block or to characterise the shape of one in progress.
    TEXT

    input_schema(
      properties: {
        start_date: {
          type: "string",
          description: "First day of the block, as YYYY-MM-DD."
        },
        end_date: {
          type: "string",
          description: "Last day of the block, as YYYY-MM-DD. Defaults to today."
        },
        days: {
          type: "integer",
          description: "Convenience alternative to start_date: the block is this many days " \
                       "ending on end_date. Defaults to 56 (eight weeks).",
          minimum: 7,
          maximum: 365
        }
      },
      required: []
    )

    DEFAULT_DAYS = 56
    MIN_DAYS = 7
    MAX_DAYS = 365

    # Proportion of an activity's duration spent in heart rate zone 4 or above
    # that marks it as a hard session.
    HARD_ZONE_SHARE_PCT = 20.0
    HARD_ZONES = %w[zone_4 zone_5].freeze

    # Pace variability past this is a structured session — intervals, or a
    # deliberately varied effort — rather than a steady run.
    STRUCTURED_PACE_CV = 0.20

    # A quartile over three activities is not a quartile. Below this the
    # top-quartile load rule sits out rather than qualifying the hardest of a
    # handful of easy runs.
    MIN_ACTIVITIES_FOR_QUARTILE = 4

    class << self
      def call(start_date: nil, end_date: nil, days: nil, server_context: nil)
        zone = runner_time_zone
        resolved = resolve_range(start_date, end_date, days, zone)
        return resolved if resolved.is_a?(MCP::Tool::Response)

        from, to, clamped = resolved
        window = TrainingWindow.between(from, to, zone: zone)
        qualifications = key_workout_qualifications(window)

        shaped(
          block: block_description(window, clamped),
          training_context: TrainingContext.current(zone: zone).to_h,
          volume: window.volume,
          terrain: window.terrain,
          load: window.load,
          intensity_distribution: window.intensity_distribution,
          aerobic_signals: window.aerobic_signals,
          weekly_breakdown: window.weekly_buckets.map(&:to_h),
          peak_week: peak_week(window),
          longest_run: longest_run(window),
          key_workouts: key_workouts(window, qualifications),
          races: races(window),
          notable: notable_signals(window, qualifications, clamped)
        )
      end

      private

      # Returns [from, to, clamped_days_or_nil], or a failure response.
      def resolve_range(start_date, end_date, days, zone)
        to = end_date.present? ? parse_date(end_date) : zone.today
        return to if to.is_a?(MCP::Tool::Response)

        from = if start_date.present?
          parse_date(start_date)
        else
          to - (days_param(days, default: DEFAULT_DAYS, min: MIN_DAYS, max: MAX_DAYS) - 1)
        end
        return from if from.is_a?(MCP::Tool::Response)

        if from > to
          return failure("start_date (#{from}) falls after end_date (#{to}). A block cannot end before it begins.")
        end

        # A block longer than a year is a history question rather than a block
        # question. The start moves rather than the request being rejected, and
        # the response says the range was shortened.
        length = (to - from).to_i + 1
        return [ to - (MAX_DAYS - 1), to, length ] if length > MAX_DAYS

        [ from, to, nil ]
      end

      def parse_date(value)
        Date.strptime(value, "%Y-%m-%d")
      rescue Date::Error
        failure("Could not read #{value.inspect} as a date. Use YYYY-MM-DD.")
      end

      def block_description(window, clamped)
        window.period.merge(
          weeks: window.weeks.round(1),
          note: ("Requested range of #{clamped} days was shortened to #{MAX_DAYS}." if clamped)
        ).compact
      end

      # Peak week is taken over complete weeks only: a week clipped by the block
      # boundary holds less than seven days of training and would understate
      # itself into never being the peak, or — for a block that starts mid-week
      # on a big day — overstate a fragment.
      def peak_week(window)
        candidates = window.weekly_buckets.select(&:complete?)
        basis = "Highest weekly distance across the complete weeks of the block."

        if candidates.empty?
          candidates = window.weekly_buckets
          basis = "Highest weekly distance. No week of the block falls entirely inside it, " \
                  "so partial weeks were considered."
        end

        peak = candidates.max_by { |bucket| bucket.activities.filter_map(&:distance_meters).sum }
        return { basis: basis, week: nil } if peak.nil? || peak.activity_count.zero?

        { basis: basis, week: peak.to_h }
      end

      def longest_run(window)
        activity = window.activities.select(&:distance_meters).max_by(&:distance_meters)
        return nil if activity.nil?

        summarise(activity, window)
      end

      def races(window)
        window.races.map do |activity|
          summarise(activity, window).merge(
            race_name: activity.race.name,
            target_time_seconds: activity.race.target_time_seconds,
            result_time_seconds: activity.race.result_time_seconds
          ).compact
        end
      end

      def summarise(activity, window)
        {
          date: window.local_date(activity).to_s,
          distance_km: activity.distance_meters ? (activity.distance_meters / 1000.0).round(2) : nil,
          duration_seconds: activity.duration_seconds&.round,
          average_pace_per_km: activity.average_pace_per_km&.round(1),
          avg_grade_adjusted_pace_per_km: activity.avg_grade_adjusted_pace_per_km&.round(1),
          elevation_gain_meters: activity.elevation_gain_meters&.round,
          tss_score: activity.tss_score&.round(1),
          pace_cv: activity.pace_cv&.round(3),
          time_above_zone_4_pct: hard_zone_share(activity)&.round(1)
        }
      end

      def key_workouts(window, qualifications)
        window.activities.filter_map do |activity|
          reasons = qualifications[activity]
          next if reasons.blank?

          summarise(activity, window).merge(qualified_as: reasons)
        end
      end

      # Five rules, any one of which qualifies a session. Naming which fired is
      # what makes the output reusable: the same list answers "what were the hard
      # sessions" and "what were the long runs" without a second call.
      def key_workout_qualifications(window)
        qualifications = window.activities.index_with { [] }

        longest_of_each_week(window).each { |activity| qualifications[activity] << "longest_run_of_week" }
        top_quartile_by_load(window).each { |activity| qualifications[activity] << "top_quartile_load" }

        window.activities.each do |activity|
          share = hard_zone_share(activity)
          qualifications[activity] << "time_above_zone_4" if share && share > HARD_ZONE_SHARE_PCT
          qualifications[activity] << "structured_pacing" if activity.pace_cv && activity.pace_cv > STRUCTURED_PACE_CV
          qualifications[activity] << "race_effort" if activity.race?
        end

        qualifications
      end

      def longest_of_each_week(window)
        window.weekly_buckets.filter_map do |bucket|
          bucket.activities.select(&:distance_meters).max_by(&:distance_meters)
        end
      end

      def top_quartile_by_load(window)
        scored = window.activities.select(&:tss_score)
        return [] if scored.size < MIN_ACTIVITIES_FOR_QUARTILE

        threshold = quantile(scored.map(&:tss_score), 0.75)
        scored.select { |activity| activity.tss_score >= threshold }
      end

      # Share of the activity's duration spent in heart rate zone 4 or above. Nil
      # rather than zero when the pipeline derived no zone distribution, so an
      # activity with no heart rate data is not reported as an easy one.
      def hard_zone_share(activity)
        distribution = activity.hr_zone_distribution
        return nil if distribution.blank?

        HARD_ZONES.sum { |zone| distribution[zone].to_f }
      end

      def notable_signals(window, qualifications, clamped)
        signals = []

        # These two describe the request rather than the training, so they are
        # reported even for a block with nothing in it.
        if clamped
          signals << "The requested block of #{clamped} days was shortened to the last #{MAX_DAYS}."
        end

        if window.days < 7
          signals << "The block is #{window.days} days long, shorter than a week, " \
                     "so the weekly figures describe a fragment rather than a training week."
        end

        if window.empty?
          signals << "No activities recorded between #{window.from} and #{window.to}."
          return signals
        end

        signals.concat(key_workout_signals(window, qualifications))
        signals.concat(shape_signals(window))
        signals
      end

      def key_workout_signals(window, qualifications)
        qualified = qualifications.count { |_activity, reasons| reasons.any? }
        signals = []

        if qualified.zero?
          signals << "No activity in the block qualified as a key workout: no session was the longest of " \
                     "its week, in the top quartile of load, structured, above zone 4, or a race."
          return signals
        end

        signals << "#{qualified} of #{window.activities.size} activities qualified as key workouts. " \
                   "A session can qualify on more than one rule, and qualified_as says which."

        scored = window.activities.count(&:tss_score)
        if scored.zero?
          signals << "No activity in the block carries a TSS, so the top-quartile load rule " \
                     "could not be applied at all."
        elsif scored < MIN_ACTIVITIES_FOR_QUARTILE
          signals << "Only #{scored} #{'activity'.pluralize(scored)} in the block #{scored == 1 ? 'carries' : 'carry'} " \
                     "a TSS, so the top-quartile load rule was not applied."
        end

        no_zones = window.activities.count { |a| a.hr_zone_distribution.blank? }
        if no_zones.positive?
          signals << "#{no_zones} of #{window.activities.size} activities have no heart rate zone " \
                     "distribution, so the time-above-zone-4 rule could not be applied to them."
        end

        signals
      end

      def shape_signals(window)
        signals = []
        complete = window.weekly_buckets.select(&:complete?)

        if complete.size >= 2
          distances = complete.map { |bucket| bucket.activities.filter_map(&:distance_meters).sum / 1000.0 }
          peak = distances.max
          final = distances.last
          if peak.positive? && final < peak * 0.7
            signals << "The block's final complete week was #{((final / peak) * 100).round}% of its peak " \
                       "week by distance, which is the pattern of a taper or an interruption."
          end
        end

        long = window.activities.filter_map(&:distance_meters).max
        total = window.total_distance_meters
        if long && total.positive? && (long / total) > 0.35
          signals << "One run accounts for #{((long / total) * 100).round}% of the block's distance, " \
                     "so the block figures rest heavily on a single effort."
        end

        signals
      end
    end
  end
end
