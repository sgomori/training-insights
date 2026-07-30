module AnalyticalTools
  # Best efforts across the whole history, at the standard race distances plus a
  # handful of career-scale bests.
  #
  # What "personal record" means here is a deliberate narrowing, and the response
  # says so rather than letting a client assume otherwise. These are best
  # *complete efforts*: the fastest activity whose total distance fell within
  # tolerance of a standard distance. What a runner usually means by a 5k PR is
  # the fastest 5km inside any run, which would mean walking the distance and
  # time streams — and "no tool queries into a stream; they aggregate whole
  # streams" is a settled decision for this codebase. Segment records would need
  # that decision amended, not quietly excepted.
  class GetPersonalRecords < AnalyticalTool
    tool_name "get_personal_records"

    description <<~TEXT.strip
      Best efforts over the runner's whole history at the standard race
      distances, plus career bests for longest run, biggest week, biggest month,
      highest single-activity load and best efficiency factor. Records are best
      complete efforts, not best segments: a 5k record is the fastest activity
      whose own distance fell within tolerance of 5km, not the fastest 5km inside
      a longer run. Because a watch never measures the nominal distance, each
      record reports the distance actually covered alongside its equivalent time at
      the nominal distance, computed with Riegel's endurance model so that a short
      effort inside the tolerance band is not credited as if pace held constant.
      Race-linked efforts are named and preferred when two efforts tie.
    TEXT

    input_schema(
      properties: {
        distances: {
          type: "array",
          description: "Restrict to a subset of the standard distances. Defaults to all of them.",
          items: { type: "string", enum: DistanceBucket::STANDARD.map(&:key) }
        }
      },
      required: []
    )

    # Squished rather than stripped: this one is prose on the wire, not a tool
    # description, and a hard-wrapped string reads badly inside a JSON payload.
    BASIS = <<~TEXT.squish
      Best complete efforts. Each record is the effort whose own distance fell
      within the tolerance band for that distance and whose equivalent time at the
      nominal distance is fastest. Ranking on elapsed time would hand every record
      to whichever effort was shortest, and ranking on raw pace would still favour
      the short edge of the band, because a shorter effort should be faster.
      equivalent_time_at_nominal_distance therefore uses Riegel's endurance model
      with the standard exponent of 1.06, which accounts for that: it is an
      extrapolation, not a time the runner actually ran. These are not segment
      records: the fastest 5km inside a longer run is not considered, because no
      tool on this server queries into an activity's streams.
    TEXT

    # Riegel's exponent. T2 = T1 * (D2 / D1) ** 1.06 is the standard endurance
    # model for predicting one distance from another, and 1.06 is the value fitted
    # across a wide range of race results.
    RIEGEL_EXPONENT = 1.06

    class << self
      def call(distances: nil, server_context: nil)
        zone = runner_time_zone
        buckets = requested_buckets(distances)
        return buckets if buckets.is_a?(MCP::Tool::Response)

        records = buckets.filter_map { |bucket| record_for(bucket, zone) }

        shaped(
          basis: BASIS,
          history: history(zone),
          records: records,
          notable_efforts: notable_efforts(zone),
          caveats: caveats(buckets, records)
        )
      end

      private

      def requested_buckets(distances)
        return DistanceBucket.standard if distances.blank?

        requested = Array(distances).map(&:to_s)
        unknown = requested - DistanceBucket::STANDARD.map(&:key)

        if unknown.any?
          return failure(
            "Unknown #{'distance'.pluralize(unknown.size)}: #{unknown.join(', ')}. " \
            "Records are kept for #{DistanceBucket::STANDARD.map(&:key).join(', ')}."
          )
        end

        DistanceBucket.standard.select { |bucket| requested.include?(bucket.key) }
      end

      # Ranked in Ruby on the Riegel-equivalent time, which SQL cannot express
      # without embedding the model in a query. The candidate set is bounded by the
      # tolerance band, so this loads a handful of rows per distance.
      def record_for(bucket, zone)
        attempts = within_tolerance(bucket)
        paced = attempts.where.not(average_pace_per_km: nil).includes(:race).to_a
        best = paced.min_by do |activity|
          # A race-linked effort takes a tie, because a race result is the more
          # meaningful number of the two. Date last, so identical calls agree.
          [ equivalent_time(activity, bucket), activity.race_id ? 0 : 1, activity.started_at ]
        end
        return nil if best.nil?

        {
          distance_bucket: bucket.key,
          label: bucket.label,
          nominal_distance_km: bucket.nominal_km,
          tolerance_km: [ bucket.min_km, bucket.max_km ],
          attempts_considered: paced.size,
          attempts_without_pace: attempts.count - paced.size,
          best: best_effort(best, bucket, zone)
        }
      end

      def within_tolerance(bucket)
        scope = Activity.where(distance_meters: (bucket.min_km * 1000)..)
        scope = scope.where(distance_meters: ..(bucket.max_km * 1000)) if bucket.max_km
        scope
      end

      # T2 = T1 * (D2 / D1) ** 1.06, where T1 is this effort's time over its own
      # distance and D2 is the nominal one. Collapses to the effort's own time when
      # it landed exactly on the nominal distance.
      def equivalent_time(activity, bucket)
        actual_km = activity.distance_meters / 1000.0
        own_time = activity.average_pace_per_km * actual_km

        own_time * ((bucket.nominal_km / actual_km)**RIEGEL_EXPONENT)
      end

      def best_effort(activity, bucket, zone)
        pace = activity.average_pace_per_km

        {
          date: activity.started_at.in_time_zone(zone).to_date.to_s,
          actual_distance_km: (activity.distance_meters / 1000.0).round(2),
          duration_seconds: activity.duration_seconds&.round,
          pace_per_km: pace.round(1),
          grade_adjusted_pace_per_km: activity.avg_grade_adjusted_pace_per_km&.round(1),
          equivalent_time_at_nominal_distance: equivalent_time(activity, bucket).round,
          equivalent_time_model: "Riegel, exponent #{RIEGEL_EXPONENT}",
          elevation_gain_meters: activity.elevation_gain_meters&.round,
          average_heart_rate: activity.average_heart_rate,
          race_name: activity.race&.name,
          race_result_time_seconds: activity.race&.result_time_seconds
        }.compact
      end

      def history(zone)
        earliest = Activity.minimum(:started_at)
        return { activities: 0, note: "No activities have been ingested yet." } if earliest.nil?

        {
          activities: Activity.count,
          first_activity_date: earliest.in_time_zone(zone).to_date.to_s,
          spans_days: (zone.today - earliest.in_time_zone(zone).to_date).to_i + 1,
          note: "Records are drawn from the whole ingested history. Anything run before the first " \
                "activity date is not represented."
        }
      end

      # The career-scale bests, which have no distance band to sit in. Volume
      # rollups are grouped in Ruby over one narrow query rather than in SQL, so
      # the week and month boundaries land in the runner's timezone the same way
      # every other tool's do.
      def notable_efforts(zone)
        # Ordered so the max_by tie-break below is stable between identical calls
        # rather than resting on whatever order Postgres happened to return.
        by_date = Activity.order(:started_at).pluck(:started_at, :distance_meters).filter_map do |started_at, distance|
          [ started_at.in_time_zone(zone).to_date, distance ] if distance
        end

        {
          longest_run: longest_run(zone),
          biggest_week: biggest_period(by_date, :beginning_of_week, "week"),
          biggest_month: biggest_period(by_date, :beginning_of_month, "month"),
          highest_load_activity: highest_load_activity(zone),
          best_efficiency_factor: best_efficiency_factor(zone)
        }.compact
      end

      def longest_run(zone)
        activity = Activity.where.not(distance_meters: nil)
          .reorder(distance_meters: :desc, started_at: :asc).includes(:race).first
        return nil if activity.nil?

        {
          date: activity.started_at.in_time_zone(zone).to_date.to_s,
          distance_km: (activity.distance_meters / 1000.0).round(2),
          duration_seconds: activity.duration_seconds&.round,
          pace_per_km: activity.average_pace_per_km&.round(1),
          elevation_gain_meters: activity.elevation_gain_meters&.round,
          race_name: activity.race&.name
        }.compact
      end

      def biggest_period(by_date, boundary, label)
        return nil if by_date.empty?

        totals = by_date.group_by { |date, _distance| date.public_send(boundary) }
        start, activities = totals.max_by { |start, rows| [ rows.sum { |_date, distance| distance }, -start.to_time.to_i ] }

        {
          starting: start.to_s,
          distance_km: (activities.sum { |_date, distance| distance } / 1000.0).round(1),
          activity_count: activities.size,
          note: "Highest total distance in any calendar #{label} of the history."
        }
      end

      def highest_load_activity(zone)
        activity = Activity.where.not(tss_score: nil)
          .reorder(tss_score: :desc, started_at: :asc).includes(:race).first
        return nil if activity.nil?

        {
          date: activity.started_at.in_time_zone(zone).to_date.to_s,
          tss_score: activity.tss_score.round(1),
          distance_km: activity.distance_meters ? (activity.distance_meters / 1000.0).round(2) : nil,
          duration_seconds: activity.duration_seconds&.round,
          race_name: activity.race&.name
        }.compact
      end

      # Training efforts only, on the same reasoning that keeps races out of every
      # other aerobic average: a maximal effort produces an efficiency factor that
      # is not comparable with a training run's.
      def best_efficiency_factor(zone)
        activity = Activity.training_only
          .where.not(grade_adjusted_efficiency_factor: nil)
          .reorder(grade_adjusted_efficiency_factor: :desc, started_at: :asc)
          .first
        return nil if activity.nil?

        {
          date: activity.started_at.in_time_zone(zone).to_date.to_s,
          grade_adjusted_efficiency_factor: activity.grade_adjusted_efficiency_factor.round(3),
          efficiency_factor: activity.efficiency_factor&.round(3),
          distance_km: activity.distance_meters ? (activity.distance_meters / 1000.0).round(2) : nil,
          basis: "Best grade-adjusted efficiency factor over training efforts. Races are excluded, " \
                 "because a maximal effort is not comparable with a training run."
        }.compact
      end

      def caveats(buckets, records)
        caveats = []

        missing = buckets.map(&:key) - records.pluck(:distance_bucket)
        if missing.any?
          caveats << "No effort within tolerance of #{missing.to_sentence}, so #{missing.size == 1 ? 'that record is' : 'those records are'} " \
                     "omitted rather than reported as empty."
        end

        unpaced = records.sum { |record| record[:attempts_without_pace] }
        if unpaced.positive?
          caveats << "#{unpaced} #{'effort'.pluralize(unpaced)} of a qualifying distance carry no average " \
                     "pace and could not be ranked."
        end

        thin = records.select { |record| record[:attempts_considered] == 1 }
        if thin.any?
          caveats << "#{thin.map { |r| r[:distance_bucket] }.to_sentence} " \
                     "#{thin.size == 1 ? 'has' : 'have'} only one qualifying effort, so the record is " \
                     "simply that effort rather than a best of several."
        end

        caveats
      end
    end
  end
end
