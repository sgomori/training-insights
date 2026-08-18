module AnalyticalTools
  # The buildup to a race, laid out against what the runner did before their
  # previous ones.
  #
  # The comparison to past buildups is the payoff from linking activities to the
  # race calendar. Every other section here could be assembled from the other
  # tools; "your longest run was 32km, against 35km before the marathon you ran
  # in 3:12" could not, and it is the most useful thing this server can say about
  # an upcoming race.
  #
  # No verdicts anywhere. "Longest run is 32km, 76% of race distance" is shaping.
  # "You are ready" is not. The bands do the scaling and the client draws the
  # conclusion.
  class GetRaceReadiness < AnalyticalTool
    tool_name "get_race_readiness"

    description <<~TEXT.strip
      Lays out the buildup to a race: long run progression, weekly volume
      trajectory, peak week, where the current week sits against that peak, work
      done at or near goal pace, the aerobic trend through the block, and the same
      figures recomputed for every past race of comparable distance alongside what
      the runner actually ran. Defaults to the next scheduled race; a specific race
      or a hypothetical date and distance can be given instead. Reports figures and
      reference bands, never a readiness verdict — the numbers are for the caller
      to interpret.
    TEXT

    input_schema(
      properties: {
        race_id: {
          type: "integer",
          description: "A race from the calendar. Defaults to the next upcoming race."
        },
        race_date: {
          type: "string",
          description: "Analyse a hypothetical race on this date, as YYYY-MM-DD. Requires race_distance_km."
        },
        race_distance_km: {
          type: "number",
          description: "Distance of the hypothetical race in kilometres. Requires race_date.",
          minimum: 0.1
        }
      },
      required: []
    )

    BUILDUP_WEEKS = 16

    # Grade-adjusted pace within this fraction of goal pace counts as race-pace
    # work. Grade-adjusted, because race pace on a hill is not race pace.
    RACE_PACE_TOLERANCE = 0.03

    # A past race counts as comparable when its distance is within this fraction
    # of the target's. A half-marathon buildup is not a useful comparison for a
    # marathon, and a 10k buildup is not one for either.
    COMPARABLE_DISTANCE_TOLERANCE = 0.20

    # The target of the analysis, whether it came from the calendar or was
    # supplied as a hypothetical.
    Target = Struct.new(:name, :date, :distance_meters, :target_time_seconds, :result_time_seconds,
      :status, :race_id, keyword_init: true) do
      def distance_km = (distance_meters / 1000.0).round(2)

      def target_pace_per_km
        return nil if target_time_seconds.nil? || distance_meters.to_f <= 0

        (target_time_seconds / (distance_meters / 1000.0)).round(1)
      end
    end

    class << self
      def call(race_id: nil, race_date: nil, race_distance_km: nil, server_context: nil)
        zone = runner_time_zone
        target = resolve_target(race_id, race_date, race_distance_km, zone)
        return target if target.is_a?(MCP::Tool::Response)

        buildup = buildup_window(target, zone)
        buckets = buildup[:window].weekly_buckets
        peak = peak_week(buckets)
        pace_work = race_pace_work(buildup[:window], target)
        past = past_races(target, zone)

        shaped(
          race: race_block(target, zone),
          training_context: TrainingContext.current(zone: zone).to_h,
          buildup: buildup[:description],
          weekly_volume_trajectory: weekly_volume_trajectory(buckets),
          long_run_progression: long_run_progression(buckets, target),
          peak_week: peak&.to_h,
          taper_status: taper_status(buckets, peak),
          race_pace_work: pace_work,
          aerobic_trend: aerobic_trend(buckets),
          comparison_to_past_buildups: comparison_to_past_buildups(target, buildup, past, zone),
          notable: notable_signals(target, buildup, buckets, peak, pace_work, past)
        )
      end

      private

      def resolve_target(race_id, race_date, race_distance_km, zone)
        return target_from_id(race_id) if race_id.present?
        return hypothetical_target(race_date, race_distance_km) if race_date.present? || race_distance_km.present?

        race = Race.next_race
        return target_from_race(race) if race

        failure(
          "No race to analyse. The calendar holds no upcoming race, so pass a race_id for a past race, " \
          "or a race_date and race_distance_km to analyse a hypothetical one."
        )
      end

      def target_from_id(race_id)
        race = Race.find_by(id: race_id)
        return failure("No race with id #{race_id} exists in the calendar.") if race.nil?

        target_from_race(race)
      end

      # The result is resolved once, here, falling back to the linked effort's
      # duration when the calendar carries no recorded time. Every caller then
      # reads one already-resolved figure rather than re-deriving the fallback.
      def target_from_race(race)
        Target.new(
          name: race.name, date: race.race_date, distance_meters: race.distance_meters,
          target_time_seconds: race.target_time_seconds,
          result_time_seconds: race.result_time_seconds || race.activity&.duration_seconds&.round,
          status: race.status, race_id: race.id
        )
      end

      def hypothetical_target(race_date, race_distance_km)
        if race_date.blank? || race_distance_km.blank?
          return failure("A hypothetical race needs both race_date and race_distance_km.")
        end

        date = begin
          Date.strptime(race_date, "%Y-%m-%d")
        rescue Date::Error
          return failure("Could not read #{race_date.inspect} as a date. Use YYYY-MM-DD.")
        end

        Target.new(
          name: "Hypothetical #{race_distance_km.to_f.round(1)}km on #{date}",
          date: date, distance_meters: race_distance_km.to_f * 1000, status: "hypothetical"
        )
      end

      def race_block(target, zone)
        days_until = (target.date - zone.today).to_i

        {
          name: target.name,
          date: target.date.to_s,
          status: target.status,
          days_until: days_until,
          has_happened: days_until.negative?,
          distance_km: target.distance_km,
          target_time_seconds: target.target_time_seconds,
          target_pace_per_km: target.target_pace_per_km,
          result_time_seconds: target.result_time_seconds,
          note: race_note(target, days_until)
        }.compact
      end

      def race_note(target, days_until)
        notes = []
        notes << "This race has already happened, #{days_until.abs} days ago." if days_until.negative?
        if target.target_time_seconds.nil?
          notes << "No target time is set, so goal-pace comparisons are unavailable."
        end
        notes.presence&.join(" ")
      end

      # The 16 weeks before the race, cut off at today for a race that has not
      # happened yet, and shortened at the start when the history does not reach
      # back that far. All three cases are named in the description, because a
      # peak week drawn from six weeks of history means something different from
      # one drawn from sixteen.
      #
      # The window ends the day before the race, not on it. A race is not part of
      # its own preparation: counting it would make race week the peak week of
      # every completed buildup, and would make a past buildup incomparable with
      # an upcoming one, which by definition contains no race yet.
      def buildup_window(target, zone)
        nominal_from = target.date - (BUILDUP_WEEKS * 7)
        earliest = Activity.minimum(:started_at)&.in_time_zone(zone)&.to_date
        to = [ target.date - 1, zone.today ].min
        # Clamped to `to`: history can begin after the buildup window closes — a
        # race last week with the first ingested activity yesterday — and an
        # inverted range would give a zero-length window to divide by.
        from = [ [ nominal_from, earliest ].compact.max, to ].min

        window = TrainingWindow.between(from, to, zone: zone)
        {
          window: window,
          truncated_by_history: earliest.present? && earliest > nominal_from,
          days_remaining: [ (target.date - zone.today).to_i, 0 ].max,
          description: {
            from: from.to_s,
            to: to.to_s,
            weeks_covered: window.weeks.round(1),
            nominal_weeks: BUILDUP_WEEKS,
            days_of_buildup_remaining: [ (target.date - zone.today).to_i, 0 ].max,
            basis: buildup_basis(target, zone, earliest, nominal_from, window)
          }
        }
      end

      def buildup_basis(target, zone, earliest, nominal_from, window)
        parts = [ "The #{BUILDUP_WEEKS} weeks before the race, ending the day before it. " \
                  "The race itself is excluded, so it cannot count as its own preparation." ]

        if earliest.nil?
          parts << "No activities have been recorded, so the buildup is empty."
        elsif earliest > nominal_from
          parts << "History begins #{earliest}, so the window starts there instead."
        end

        if target.date > zone.today
          parts << "The race is #{(target.date - zone.today).to_i} days away, so the buildup is incomplete " \
                   "and every figure below covers only the part already run."
        end

        parts << "Covers #{window.weeks.round(1)} of the #{BUILDUP_WEEKS} weeks."
        parts.join(" ")
      end

      def weekly_volume_trajectory(buckets)
        buckets.map do |bucket|
          {
            week_start: bucket.week_start.to_s,
            distance_km: bucket.distance_km,
            tss: bucket.tss,
            activity_count: bucket.activity_count,
            complete_week: bucket.complete?
          }
        end
      end

      # The share is routed through MetricInterpretation rather than emitted bare.
      # "76%" reads as low to a client thinking about 10k races and as textbook to
      # one thinking about marathons, and the guidance is what distinguishes them.
      def long_run_progression(buckets, target)
        race_km = target.distance_meters / 1000.0
        peak_share = nil

        series = buckets.map do |bucket|
          longest = bucket.longest_run_km
          share = longest && race_km.positive? ? ((longest / race_km) * 100).round(1) : nil
          peak_share = [ peak_share, share ].compact.max

          {
            week_start: bucket.week_start.to_s,
            longest_run_km: longest,
            pct_of_race_distance: share,
            complete_week: bucket.complete?,
            week_in_progress: bucket.in_progress?
          }
        end

        {
          longest_run_pct_of_race_distance: MetricInterpretation.describe(
            :long_run_pct_of_race_distance, value: peak_share
          ),
          by_week: series
        }
      end

      # Whole and finished weeks only. A week still being run understates itself,
      # and would never be named the peak however hard it turns out to be.
      def peak_week(buckets)
        candidates = buckets.select { |bucket| bucket.comparable? && bucket.activity_count.positive? }
        candidates = buckets.select { |bucket| bucket.activity_count.positive? } if candidates.empty?
        candidates.max_by { |bucket| bucket.activities.filter_map(&:distance_meters).sum }
      end

      # Reports where the most recent week sits against the peak. Does not label
      # it: whether a ratio of 0.6 is a well-executed taper or an interrupted
      # block depends on the plan, which this server does not know.
      def taper_status(buckets, peak)
        latest = buckets.last
        return { note: "The buildup contains no weeks." } if latest.nil? || peak.nil?

        peak_km = peak.distance_km
        ratio = peak_km.positive? ? (latest.distance_km / peak_km).round(2) : nil

        {
          peak_week_start: peak.week_start.to_s,
          latest_week_start: latest.week_start.to_s,
          weeks_from_peak: ((latest.week_start - peak.week_start).to_i / 7),
          latest_week_distance_km: latest.distance_km,
          peak_week_distance_km: peak_km,
          current_week_vs_peak: taper_comparison(latest, ratio)
        }
      end

      # A week still being run is not banded at all.
      #
      # The peak is chosen from comparable weeks, so banding the latest one
      # against it compares a part-week with a whole one: on the first day of a
      # week that reads as "deep taper or interruption", and on the last day it
      # reads as a finished week even though the long run may still be ahead
      # that afternoon. Naming a band and appending a caveat leaves the client
      # to discount the band. Withholding it is the server doing that work.
      def taper_comparison(latest, ratio)
        return MetricInterpretation.describe(:taper_ratio, value: ratio) if latest.comparable?

        {
          value: ratio,
          band: nil,
          note: "The most recent week is #{latest.days_in_window} " \
                "#{'day'.pluralize(latest.days_in_window)} into a seven-day week and is still being " \
                "run, so its volume is not yet comparable with a finished week's and is not " \
                "interpreted here."
        }
      end

      # Counting activities whose grade-adjusted pace sits near goal pace. Whole
      # activities only: a long run with a race-pace finish averages out and will
      # not be counted, because no tool here reads into an activity's streams.
      def race_pace_work(window, target)
        goal = target.target_pace_per_km

        if goal.nil?
          return {
            basis: "No target time is set for this race, so there is no goal pace to compare against. " \
                   "Set a target time on the race to enable this section."
          }
        end

        tolerance = goal * RACE_PACE_TOLERANCE
        band = (goal - tolerance)..(goal + tolerance)
        matching = window.training_only.select do |activity|
          activity.avg_grade_adjusted_pace_per_km && band.cover?(activity.avg_grade_adjusted_pace_per_km)
        end
        measurable = window.training_only.count(&:avg_grade_adjusted_pace_per_km)

        {
          target_pace_per_km: goal,
          tolerance_seconds_per_km: tolerance.round(1),
          activities_at_or_near_target: matching.size,
          total_km_near_target: (matching.filter_map(&:distance_meters).sum / 1000.0).round(1),
          longest_km_near_target: matching.filter_map(&:distance_meters).max&.then { |m| (m / 1000.0).round(1) },
          activities_measurable: measurable,
          basis: "Training efforts whose whole-activity grade-adjusted pace fell within " \
                 "#{(RACE_PACE_TOLERANCE * 100).round}% of goal pace. Grade-adjusted on the training side, " \
                 "because race pace on a hill is not race pace. The goal pace itself is not grade-adjusted " \
                 "— it is the target time over the nominal distance — so this comparison assumes a flat " \
                 "course. On a hilly one the grade-adjusted pace needed to hit the target is faster than " \
                 "the figure here, and the count will read high. Whole activities only, so a long run with " \
                 "a race-pace finish does not count: its average is slower than the segment that mattered. " \
                 "#{window.training_only.size - measurable} training efforts carry no grade-adjusted pace."
        }
      end

      def aerobic_trend(buckets)
        {
          basis: "Per week over the buildup, training efforts only. Falling decoupling and rising " \
                 "grade-adjusted efficiency factor are the aerobic signals a buildup is meant to move.",
          decoupling_series: weekly_metric(buckets, :aerobic_decoupling_pct, 1),
          grade_adjusted_ef_series: weekly_metric(buckets, :grade_adjusted_efficiency_factor, 3)
        }
      end

      def weekly_metric(buckets, column, precision)
        buckets.map do |bucket|
          training = bucket.activities.reject(&:race?)
          stat = mean_with_sample(training.map(&column), precision: precision)

          { week_start: bucket.week_start.to_s, value: stat[:value], sample_size: stat[:sample_size] }
        end
      end

      # The payoff from race linkage: for every past race of comparable distance,
      # the same buildup figures alongside the result they produced.
      #
      # The target buildup appears in the same key shape as the past ones. Without
      # it the client has to reassemble peak week, longest run and average weekly
      # volume for the target from other blocks in order to use the very block
      # whose purpose is a side-by-side.
      #
      # Every buildup here is truncated at the start of history exactly as the
      # target's is, and reports weeks_covered. Dividing a total by a nominal 16
      # weeks when only one week of training could have existed reported 2.8km per
      # week beside a 45km peak week — both figures correct, the pair of them
      # false — and a client comparing that against a current 40km per week would
      # read a fourteenfold increase that never happened.
      def comparison_to_past_buildups(target, buildup, past, zone)
        {
          basis: "Each buildup is the #{BUILDUP_WEEKS} weeks before its race, ending the day before it, " \
                 "truncated where history does not reach back that far. Compare per-week figures across " \
                 "buildups of differing weeks_covered; totals are not comparable between them. " \
                 "history_covers_full_buildup says whether the window was cut short.",
          this_buildup: buildup_summary(target, buildup[:window]),
          past: past.map { |race| past_buildup_summary(race, zone) }
        }
      end

      def past_buildup_summary(race, zone)
        buildup_summary(target_from_race(race), truncated_buildup(race.race_date, zone))
      end

      # The buildup window for any race, truncated at the start of history the
      # same way the target's is.
      def truncated_buildup(race_date, zone)
        nominal_from = race_date - (BUILDUP_WEEKS * 7)
        earliest = Activity.minimum(:started_at)&.in_time_zone(zone)&.to_date
        to = race_date - 1

        TrainingWindow.between([ [ nominal_from, earliest ].compact.max, to ].min, to, zone: zone)
      end

      # One key set for the target buildup and every past one, result keys
      # included and null where the race has not been run. Two shapes would put
      # the client back to assembling the comparison itself.
      def buildup_summary(target, window)
        peak = window.weekly_buckets.select { |bucket| bucket.comparable? && bucket.activity_count.positive? }
          .max_by(&:distance_km)

        {
          race_name: target.name,
          race_date: target.date.to_s,
          distance_km: target.distance_km,
          result_time_seconds: target.result_time_seconds,
          result_pace_per_km: result_pace(target.result_time_seconds, target.distance_meters),
          peak_week_km: peak&.distance_km,
          longest_run_km: window.volume[:longest_run_km],
          average_weekly_km: (window.total_distance_meters / 1000.0 / window.weeks).round(1),
          total_tss: window.total_tss.round(1),
          weeks_covered: window.weeks.round(1),
          history_covers_full_buildup: window.days >= BUILDUP_WEEKS * 7
        }
      end

      def past_races(target, zone)
        tolerance = target.distance_meters * COMPARABLE_DISTANCE_TOLERANCE
        band = (target.distance_meters - tolerance)..(target.distance_meters + tolerance)

        Race.completed
          .includes(:activity)
          .where(race_date: ...target.date)
          .where(distance_meters: band)
          .where.not(id: target.race_id)
          .to_a
          .select { |race| race.race_date <= zone.today }
      end

      def result_pace(seconds, distance_meters)
        return nil if seconds.nil? || distance_meters.to_f <= 0

        (seconds / (distance_meters / 1000.0)).round(1)
      end

      def notable_signals(target, buildup, buckets, peak, pace_work, past)
        window = buildup[:window]
        days_until = (target.date - window.zone.today).to_i
        signals = []

        signals.concat(timing_signals(target, buildup, days_until))

        if window.empty?
          signals << "No activities recorded in the buildup window (#{window.from} to #{window.to})."
        else
          signals.concat(long_run_signals(buckets, target))
          signals.concat(taper_signals(buckets, peak))
          signals.concat(race_pace_signals(pace_work, target))
        end

        # Reported either way: whether a comparable past race exists is a fact
        # about the calendar, not about the buildup that has been run so far.
        signals.concat(past_buildup_signals(target, past))
        signals
      end

      def timing_signals(target, buildup, days_until)
        signals = []

        if days_until.negative?
          signals << "This race was #{days_until.abs} days ago. The buildup below is complete, " \
                     "so read it as a review rather than a forecast."
        elsif days_until <= 7
          signals << "The race is #{days_until} #{'day'.pluralize(days_until)} away, " \
                     "so the buildup is essentially finished."
        end

        if buildup[:truncated_by_history]
          signals << "History does not reach back a full #{BUILDUP_WEEKS} weeks before this race, " \
                     "so the buildup covers #{buildup[:description][:weeks_covered]} weeks rather than " \
                     "#{BUILDUP_WEEKS}. Peak week and averages are drawn from that shorter span."
        end

        signals
      end

      def long_run_signals(buckets, target)
        race_km = target.distance_meters / 1000.0
        longest = buckets.filter_map(&:longest_run_km).max
        return [] if longest.nil? || race_km <= 0

        pct = ((longest / race_km) * 100).round
        [ "The buildup's longest run is #{longest}km, #{pct}% of the #{target.distance_km}km race distance." ]
      end

      def taper_signals(buckets, peak)
        return [] if peak.nil?

        latest = buckets.last
        return [] if latest.nil? || peak.distance_km <= 0

        weeks_since = (latest.week_start - peak.week_start).to_i / 7
        return [] if weeks_since.zero?

        # notable is the first thing a client reads, so a week still being run
        # is left out of it entirely rather than named with a caveat attached.
        # taper_status still reports the raw ratio and says why it is not
        # interpreted.
        return [] unless latest.comparable?

        ratio = (latest.distance_km / peak.distance_km).round(2)
        band = MetricInterpretation.describe(:taper_ratio, value: ratio)[:band]

        [ "The most recent week covered #{latest.distance_km}km against a peak of " \
          "#{peak.distance_km}km #{weeks_since} #{'week'.pluralize(weeks_since)} earlier — " \
          "a ratio of #{ratio} (#{band})." ]
      end

      def race_pace_signals(pace_work, target)
        goal = target.target_pace_per_km
        return [ "No target time is set for this race, so no goal-pace work could be identified." ] if goal.nil?

        return [] unless pace_work[:activities_at_or_near_target]&.zero?

        [ "No training effort in the buildup averaged within " \
          "#{(RACE_PACE_TOLERANCE * 100).round}% of the #{goal}s/km goal pace. Note this counts whole " \
          "activities only, so a goal-pace block inside a longer run is invisible to it. The buildup's " \
          "longer runs are the place to look, and describe_run will show a block inside one where the " \
          "laps recorded it." ]
      end

      def past_buildup_signals(target, races)
        if races.empty?
          return [ "No past race within #{(COMPARABLE_DISTANCE_TOLERANCE * 100).round}% of " \
                   "#{target.distance_km}km has been completed, so there is no previous buildup to " \
                   "compare against." ]
        end

        [ "#{races.size} past #{'race'.pluralize(races.size)} of comparable distance " \
          "#{races.size == 1 ? 'is' : 'are'} reported alongside this buildup, each with the buildup that " \
          "preceded it and the time it produced." ]
      end
    end
  end
end
