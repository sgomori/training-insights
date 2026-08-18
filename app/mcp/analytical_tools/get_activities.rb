module AnalyticalTools
  # The escape hatch, and the only tool on this server permitted to return a
  # list.
  #
  # Every other tool answers a question with an aggregation. This one exists for
  # the cases where the client genuinely needs the individual efforts — checking
  # a specific week, finding the run behind a figure another tool surfaced,
  # eyeballing freshly backfilled data. It is deliberately the exception, and the
  # response says how much of the matching set it is showing so a truncated view
  # is never mistaken for the whole one.
  #
  # Curated columns only. No streams and no GPS — the schema has no column to
  # hold a route, so there is nothing here to leak. Laps are describe_run's
  # business: a list of efforts is the wrong place to unfold one of them.
  class GetActivities < AnalyticalTool
    tool_name "get_activities"

    description <<~TEXT.strip
      Returns individual activities matching a filter, with their headline and
      computed metrics. This is the only tool that returns a list rather than an
      aggregation — prefer get_recent_activity_summary, get_training_load or
      get_training_block_summary for any question about a period as a whole, and
      reach for this one when you need the specific efforts behind a figure.
      Filter by date range, activity type, distance range or races only. Always
      reports how many activities matched against how many were returned, so a
      truncated result is visible rather than silent. Streams and route data are
      not available through any tool; for what happened inside one of these
      efforts, use describe_run.
    TEXT

    input_schema(
      properties: {
        from: {
          type: "string",
          description: "Earliest activity date to include, as YYYY-MM-DD. Defaults to the start of history."
        },
        to: {
          type: "string",
          description: "Latest activity date to include, as YYYY-MM-DD. Defaults to today."
        },
        activity_type: {
          type: "string",
          description: "Restrict to one activity type, for example \"running\". Defaults to all types."
        },
        min_distance_km: {
          type: "number",
          description: "Exclude activities shorter than this. Activities with no recorded distance are excluded too.",
          minimum: 0
        },
        max_distance_km: {
          type: "number",
          description: "Exclude activities longer than this. Activities with no recorded distance are excluded too.",
          minimum: 0
        },
        races_only: {
          type: "boolean",
          description: "Return only efforts linked to a race in the calendar. Defaults to false."
        },
        limit: {
          type: "integer",
          description: "Maximum activities to return. Defaults to 50, capped at 200.",
          minimum: 1,
          maximum: 200
        },
        order: {
          type: "string",
          description: "Sort order for the returned list.",
          enum: %w[newest_first oldest_first longest_first fastest_first]
        }
      },
      required: []
    )

    DEFAULT_LIMIT = 50
    MAX_LIMIT = 200
    DEFAULT_ORDER = "newest_first"

    # NULLS LAST is explicit rather than left to the default, which differs by
    # direction in PostgreSQL: a descending sort would otherwise head a
    # "longest first" list with the activities whose distance was never recorded.
    # Lower pace is faster, so fastest_first sorts ascending.
    ORDERS = {
      "newest_first" => "started_at DESC",
      "oldest_first" => "started_at ASC",
      "longest_first" => "distance_meters DESC NULLS LAST",
      "fastest_first" => "average_pace_per_km ASC NULLS LAST"
    }.freeze

    class << self
      def call(from: nil, to: nil, activity_type: nil, min_distance_km: nil, max_distance_km: nil,
               races_only: nil, limit: nil, order: nil, server_context: nil)
        zone = runner_time_zone

        if min_distance_km && max_distance_km && min_distance_km.to_f > max_distance_km.to_f
          return failure(
            "min_distance_km (#{min_distance_km}) is greater than max_distance_km (#{max_distance_km}), " \
            "so no activity can match. Swap them or drop one."
          )
        end

        from_date = parse_date(from)
        return from_date if from_date.is_a?(MCP::Tool::Response)

        to_date = parse_date(to)
        return to_date if to_date.is_a?(MCP::Tool::Response)

        limit_defaulted = limit.nil?
        limit = (limit || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
        order = ORDERS.key?(order) ? order : DEFAULT_ORDER

        scope = filtered(
          zone: zone, from_date: from_date, to_date: to_date, activity_type: activity_type,
          min_distance_km: min_distance_km, max_distance_km: max_distance_km, races_only: races_only
        )

        total = scope.count
        activities = scope.reorder(Arel.sql(ORDERS.fetch(order))).limit(limit).includes(:race).to_a

        shaped(
          filters_applied: filters_applied(
            zone: zone, from_date: from_date, to_date: to_date, activity_type: activity_type,
            min_distance_km: min_distance_km, max_distance_km: max_distance_km,
            races_only: races_only, limit: limit, order: order
          ),
          total_matching: total,
          returned: activities.size,
          truncated: total > activities.size,
          activities: activities.map { |activity| present(activity, zone) },
          notable: notable_signals(
            total: total, returned: activities.size, limit_defaulted: limit_defaulted,
            distance_filtered: !min_distance_km.nil? || !max_distance_km.nil?
          )
        )
      end

      private

      def parse_date(value)
        return nil if value.blank?

        Date.strptime(value, "%Y-%m-%d")
      rescue Date::Error
        failure("Could not read #{value.inspect} as a date. Use YYYY-MM-DD.")
      end

      def filtered(zone:, from_date:, to_date:, activity_type:, min_distance_km:, max_distance_km:, races_only:)
        scope = Activity.all
        scope = scope.where(started_at: zone.parse(from_date.to_s).beginning_of_day..) if from_date
        scope = scope.where(started_at: ..zone.parse(to_date.to_s).end_of_day) if to_date
        scope = scope.of_type(activity_type) if activity_type.present?
        scope = scope.where(distance_meters: (min_distance_km.to_f * 1000)..) if min_distance_km
        scope = scope.where(distance_meters: ..(max_distance_km.to_f * 1000)) if max_distance_km
        scope = scope.races if races_only
        scope
      end

      # Echoed back so the response stands on its own. A list of activities with
      # no statement of what produced it cannot be reasoned about a turn later.
      def filters_applied(zone:, from_date:, to_date:, activity_type:, min_distance_km:, max_distance_km:,
                          races_only:, limit:, order:)
        {
          from: from_date&.to_s || "start of history",
          to: to_date&.to_s || "today (#{zone.today})",
          timezone: zone.name,
          activity_type: activity_type.presence || "all",
          min_distance_km: min_distance_km,
          max_distance_km: max_distance_km,
          races_only: races_only.present?,
          limit: limit,
          order: order
        }.compact
      end

      def present(activity, zone)
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
          tss_score: activity.tss_score&.round(1),
          efficiency_factor: activity.efficiency_factor&.round(3),
          grade_adjusted_efficiency_factor: activity.grade_adjusted_efficiency_factor&.round(3),
          aerobic_decoupling_pct: activity.aerobic_decoupling_pct&.round(1),
          pace_cv: activity.pace_cv&.round(3),
          race: race_for(activity)
        }
      end

      def race_for(activity)
        return nil unless activity.race

        race = activity.race
        {
          name: race.name,
          date: race.race_date.to_s,
          distance_km: (race.distance_meters / 1000.0).round(1),
          target_time_seconds: race.target_time_seconds,
          result_time_seconds: race.result_time_seconds
        }.compact
      end

      def notable_signals(total:, returned:, limit_defaulted:, distance_filtered:)
        signals = []

        if total.zero?
          signals << "No activities match these filters."
          return signals
        end

        if total > returned
          signals << "#{total} activities match but only #{returned} were returned. " \
                     "Narrow the date range or raise the limit (capped at #{MAX_LIMIT}) to see the rest, " \
                     "or use an aggregating tool if the question is about the period as a whole."
        elsif limit_defaulted
          signals << "No limit was requested, so the default of #{DEFAULT_LIMIT} applied. " \
                     "It did not truncate this result."
        end

        if distance_filtered
          signals << "A distance filter is applied, so activities with no recorded distance are " \
                     "excluded regardless of how far they went."
        end

        signals
      end
    end
  end
end
