module AnalyticalTools
  # What one run actually looked like from the inside.
  #
  # Every other tool on this server aggregates across activities. This one goes
  # the other way and describes a single effort — its headline figures, and the
  # phases its laps fall into. It exists because "he averaged 5:45 for 15 km" and
  # "he ran 8 km steady and then six hard kilometres" are different facts, and no
  # aggregation can recover the second from the first.
  #
  # Laps only. No stream is read here, so a fastest segment that does not align
  # with a lap boundary remains unanswerable — see the segmentation module for
  # what that costs and when.
  class DescribeRun < AnalyticalTool
    tool_name "describe_run"

    description <<~TEXT.strip
      Describes a single run from the inside: its headline figures plus the
      phases its laps fall into, so an interval session reads as repeats with
      their per-rep paces rather than as one average. Selects the most recent
      activity by default, or pass a date. Reports the lap basis it worked from,
      because a session lapped every kilometre describes kilometres while one
      lapped per rep describes reps, and states when the laps are too few or too
      uniform to carry a shape rather than inventing one. Individual lap splits
      are not returned. Use it for questions about a specific effort; use the
      aggregating tools for questions about a period.
    TEXT

    input_schema(
      properties: {
        date: {
          type: "string",
          description: "The day to describe, as YYYY-MM-DD. Defaults to the most recent activity. " \
                       "Where the day holds more than one activity, the longest is described and the " \
                       "others are named."
        },
        started_at: {
          type: "string",
          description: "Exact start time as an ISO 8601 timestamp, to pick one activity out of a day " \
                       "that holds several. Overrides date."
        }
      },
      required: []
    )

    # Timestamps on the wire carry whole seconds while the column carries
    # microseconds, so an exact match would reject a value a client read out of
    # another tool's response and handed straight back.
    RESOLUTION = 1.second

    # The lower bound of pace_cv's "variable" band. Named here rather than
    # inlined so the two cannot drift apart silently.
    VARIABLE_PACE_CV = 0.15

    # Below this a faster stretch is a surge, not a block worth calling out on
    # its own.
    SUSTAINED_EFFORT_KM = 2.0

    class << self
      def call(date: nil, started_at: nil, server_context: nil)
        zone = runner_time_zone

        target = parse_target(date: date, started_at: started_at, zone: zone)
        return target if target.is_a?(MCP::Tool::Response)

        activity, alternatives = resolve(target, zone)
        return miss(target, date: date, started_at: started_at, zone: zone) if activity.nil?

        segmentation = LapSegmentation.call(activity.activity_laps.to_a)

        shaped(
          selection: selection(date: date, started_at: started_at, activity: activity,
                               alternatives: alternatives, zone: zone),
          activity: headline(activity, zone),
          aerobic_signals: aerobic_signals(activity, segmentation),
          pace_variability: MetricInterpretation.describe(
            :pace_cv,
            value: activity.pace_cv&.round(3),
            caveats: pace_cv_caveats(segmentation)
          ),
          structure: segmentation,
          notable: notable_signals(activity: activity, segmentation: segmentation)
        )
      end

      private

      # A time when started_at was given, a date when date was, nil for the most
      # recent activity, or the failure response for a value that would not read.
      def parse_target(date:, started_at:, zone:)
        return parse_time(started_at, zone) if started_at.present?
        return parse_date(date) if date.present?

        nil
      end

      # Returns the chosen activity and anything else that shared its day, so a
      # double day is visible in the response rather than silently collapsed.
      def resolve(target, zone)
        case target
        when nil
          [ Activity.most_recent_first.first, [] ]
        when Date
          day = activities_on(target, zone)
          return [ nil, [] ] if day.empty?

          # The longest, not the first. On a double day the question is almost
          # always about the session rather than the shakeout, and the response
          # names the other efforts either way.
          chosen = day.max_by { |candidate| candidate.distance_meters.to_f }
          [ chosen, day - [ chosen ] ]
        else
          chosen = Activity.starting_between(target - RESOLUTION, target + RESOLUTION).first
          chosen.nil? ? [ nil, [] ] : [ chosen, others_that_day(chosen, zone) ]
        end
      end

      # Ordered, so a tie on distance between two efforts on one day resolves the
      # same way every call.
      def activities_on(date, zone)
        Activity.on_day(date, zone).chronological.to_a
      end

      def others_that_day(activity, zone)
        activities_on(activity.started_at.in_time_zone(zone).to_date, zone) - [ activity ]
      end

      def parse_date(value)
        Date.strptime(value, "%Y-%m-%d")
      rescue Date::Error
        failure("Could not read #{value.inspect} as a date. Use YYYY-MM-DD.")
      end

      def parse_time(value, zone)
        zone.parse(value) or raise ArgumentError
      rescue ArgumentError, TypeError
        failure("Could not read #{value.inspect} as a timestamp. Use an ISO 8601 time such as " \
                "2026-07-30T07:15:00-04:00.")
      end

      # An error, because an empty day is not a described run — but one that
      # carries what surrounds the day, as prose and as data, so a client that
      # asked about the wrong year can see that and ask again.
      def miss(target, date:, started_at:, zone:)
        return failure("No activities have been recorded yet.") if target.nil?

        headline = started_at.present? ? "No activity started at #{started_at}." : "No activity was recorded on #{date}."
        surroundings = EmptyDay.new(target.to_date, zone)

        MCP::Tool::Response.new(
          [ { type: "text", text: [ headline, surroundings.to_prose ].join(" ") } ],
          structured_content: { requested: started_at.presence || date, found: false }.merge(surroundings.to_h),
          error: true
        )
      end

      # as_of and days_ago sit beside the resolution so a client that asked
      # about the wrong year can see it landed a year off, without doing the
      # date arithmetic itself.
      def selection(date:, started_at:, activity:, alternatives:, zone:)
        {
          requested: started_at.presence || date.presence || "most recent activity",
          resolved_to: activity.started_at.in_time_zone(zone).iso8601,
          as_of: zone.today.to_s,
          days_ago: (zone.today - activity.started_at.in_time_zone(zone).to_date).to_i,
          other_activities_that_day: alternatives.map do |other|
            {
              started_at: other.started_at.in_time_zone(zone).iso8601,
              distance_km: other.distance_meters ? (other.distance_meters / 1000.0).round(2) : nil
            }.compact
          end.presence
        }.compact
      end

      # Not compacted. A null is what the server instructions promise when the
      # source data lacked what a figure needed, and an absent key would leave a
      # client unable to tell a missing measurement from a misremembered name.
      def headline(activity, zone)
        {
          date: activity.started_at.in_time_zone(zone).to_date.to_s,
          started_at: activity.started_at.in_time_zone(zone).iso8601,
          activity_type: activity.activity_type,
          distance_km: activity.distance_meters ? (activity.distance_meters / 1000.0).round(2) : nil,
          duration_seconds: activity.duration_seconds&.round,
          average_pace_per_km: activity.average_pace_per_km&.round(1),
          avg_grade_adjusted_pace_per_km: activity.avg_grade_adjusted_pace_per_km&.round(1),
          elevation_gain_meters: activity.elevation_gain_meters&.round,
          average_heart_rate: activity.average_heart_rate,
          max_heart_rate: activity.max_heart_rate,
          tss_score: activity.tss_score&.round(1),
          race: race_for(activity)
        }
      end

      def race_for(activity)
        return nil unless activity.race

        {
          name: activity.race.name,
          distance_km: (activity.race.distance_meters / 1000.0).round(1),
          result_time_seconds: activity.race.result_time_seconds
        }.compact
      end

      # Carried here rather than left to another call, and carried with a caveat
      # no other tool can attach: these three assume a steady effort, and this is
      # the only tool on the server that knows whether the run was one.
      def aerobic_signals(activity, segmentation)
        caveats = steady_state_caveats(segmentation)

        {
          basis: "the activity as a whole",
          aerobic_decoupling_pct: MetricInterpretation.describe(
            :aerobic_decoupling_pct, value: activity.aerobic_decoupling_pct&.round(1), caveats: caveats
          ),
          efficiency_factor: MetricInterpretation.describe(
            :efficiency_factor, value: activity.efficiency_factor&.round(3), caveats: caveats
          ),
          grade_adjusted_efficiency_factor: MetricInterpretation.describe(
            :grade_adjusted_efficiency_factor,
            value: activity.grade_adjusted_efficiency_factor&.round(3), caveats: caveats
          )
        }
      end

      def steady_state_caveats(segmentation)
        return [] unless structured?(segmentation)

        [ "The laps read as a structured session rather than a steady effort, so this figure compares " \
          "unlike halves — an easy start against hard running, or the reverse. It describes the shape " \
          "of the session, not aerobic durability." ]
      end

      # Pace variability and the lap segmentation measure the same thing from
      # different sources, and they can disagree. Saying so where they do is more
      # use than either figure alone.
      def pace_cv_caveats(segmentation)
        return [] unless segmentation[:shape] == "unavailable"

        [ "Computed from the full activity, so it still describes how varied the run was even though " \
          "the laps cannot say where the variation fell." ]
      end

      def notable_signals(activity:, segmentation:)
        [
          (race_signal(activity) if activity.race?),
          non_run_signal(activity),
          repeats_signal(segmentation),
          sustained_effort_signal(segmentation),
          continuous_signal(activity, segmentation)
        ].compact
      end

      def race_signal(activity)
        "This effort is linked to #{activity.race.name}, so it was raced rather than trained. " \
        "Its shape reflects a race plan, not a workout."
      end

      # The default selection is the most recent activity of any type, so this
      # tool can land on a ride while carrying a name and a set of fields that
      # both say run.
      def non_run_signal(activity)
        return nil if activity.activity_type == "running"

        "This activity is a #{activity.activity_type}, not a run. The pace figures below describe it " \
        "correctly but are not comparable with running paces."
      end

      def repeats_signal(segmentation)
        repeats = phases(segmentation).find { |phase| phase[:kind] == "repeats" }
        return nil unless repeats

        "#{repeats[:reps]} repetitions of about #{repeats[:rep_distance_km]} km#{rep_distance_clause(repeats)}" \
        "#{recovery_clause(repeats)}.#{drift_clause(repeats)}#{cut_short_clause(repeats)}"
      end

      def rep_distance_clause(repeats)
        range = repeats[:rep_distance_range_km]
        return "" if range.nil?

        " — though they ranged from #{range.first} to #{range.last} km"
      end

      # The set the laps support is not always the set the runner ran. Where the
      # alternation went on with efforts of another length, the count is
      # qualified rather than left to read as the whole session.
      def cut_short_clause(repeats)
        return "" if repeats[:note].nil?

        " Further fast efforts of a different length followed the set."
      end

      def recovery_clause(repeats)
        return "" if repeats[:recovery_seconds].nil?

        clause = +", with about #{repeats[:recovery_seconds]}s between them"
        if (range = repeats[:recovery_seconds_range])
          clause << " — though they ranged from #{range.first}s to #{range.last}s"
        end
        clause
      end

      # A set that faded and a set that negative-split produce identical
      # aggregates, and which of the two it was is the first thing anyone asks
      # about a workout.
      def drift_clause(repeats)
        drift = repeats[:rep_pace_drift_seconds]
        return "" if drift.nil?

        if drift.abs <= 5 then " The reps held within #{drift.abs.round}s per kilometre across the set."
        elsif drift.positive? then " They slowed by #{drift.round}s per kilometre from first to last."
        else " They quickened by #{drift.abs.round}s per kilometre from first to last."
        end
      end

      # A sustained faster block is the whole point of the session it appears in,
      # and without this the client has to scan the phases to find it. Reported
      # beside a repeats signal too: a tempo block after a set of strides is the
      # session, and the set of strides is not.
      def sustained_effort_signal(segmentation)
        block = phases(segmentation)
          .select { |phase| phase[:kind] == "faster" && phase[:distance_km].to_f >= SUSTAINED_EFFORT_KM }
          .max_by { |phase| phase[:distance_km] }
        return nil unless block

        reference = segmentation[:reference_pace_per_km]
        "A #{block[:distance_km]} km block at #{block[:pace_per_km].round}s/km, " \
        "#{(reference - block[:pace_per_km]).round}s/km faster than the run's typical pace."
      end

      # A continuous reading and a high variability figure contradict each other,
      # and the contradiction is the finding: the variation happened inside the
      # laps rather than between them.
      def continuous_signal(activity, segmentation)
        return nil unless segmentation[:shape] == "continuous"
        return nil if activity.pace_cv.nil? || activity.pace_cv < VARIABLE_PACE_CV

        "The laps read as one continuous effort, but pace variability across the whole activity is " \
        "high. The variation fell inside the laps rather than between them, which is what a session " \
        "of short efforts on a long auto-lap looks like."
      end

      def structured?(segmentation)
        segmentation[:shape] == "structured"
      end

      def phases(segmentation)
        Array(segmentation[:phases])
      end
    end
  end
end
