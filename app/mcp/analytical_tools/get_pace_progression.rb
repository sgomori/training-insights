module AnalyticalTools
  # Whether the runner is getting faster, over a horizon long enough for the
  # answer to mean something.
  #
  # Two decisions carry this tool. Grade-adjusted pace is the primary series and
  # raw pace the secondary, because over six months a change of routes moves raw
  # pace more than a season of training does — a progression tool reading raw pace
  # reports terrain as fitness. And races are excluded from the series and
  # reported separately as markers, because a race is a best effort rather than a
  # training data point, and averaging one into a monthly bucket makes that month
  # look faster than the training was.
  class GetPaceProgression < AnalyticalTool
    tool_name "get_pace_progression"

    description <<~TEXT.strip
      Pace and efficiency over time, bucketed into equal multi-week periods, for
      a chosen distance band or intensity. Read the grade-adjusted series first:
      it normalises for climbing, and raw pace over a long horizon reflects route
      choice as much as fitness. Races are excluded from the series and returned
      separately as markers, since a best effort is not a training data point.
      Buckets with too few activities to average are returned marked as such
      rather than dropped, so a gap in training stays visible. Also reports the
      least-squares trend across the buckets that do carry a sample.
    TEXT

    input_schema(
      properties: {
        distance_bucket: {
          type: "string",
          description: "Restrict the series to runs of a given distance. Standard race distances use a " \
                       "tolerance; the descriptive bands partition everything else. Defaults to \"any\".",
          enum: DistanceBucket::KEYS + [ "any" ]
        },
        intensity: {
          type: "string",
          description: "Restrict the series by intensity instead of distance, classifying each run by the " \
                       "pace zone it spent most of its time in. Mutually exclusive with distance_bucket.",
          enum: %w[easy moderate threshold hard]
        },
        days: {
          type: "integer",
          description: "Length of the history to cover, counting back from today. Defaults to 180.",
          minimum: 28,
          maximum: 730
        },
        bucket_weeks: {
          type: "integer",
          description: "Width of each bucket in the series, in weeks. Defaults to 4.",
          minimum: 1,
          maximum: 12
        }
      },
      required: []
    )

    DEFAULT_DAYS = 180
    MIN_DAYS = 28
    MAX_DAYS = 730
    DEFAULT_BUCKET_WEEKS = 4
    ANY = "any".freeze

    # Series metrics, each with the rounding it is meaningful at. Grade-adjusted
    # pace leads: it is the figure a change of route does not move.
    SERIES_METRICS = {
      avg_grade_adjusted_pace_per_km: 1,
      average_pace_per_km: 1,
      grade_adjusted_efficiency_factor: 3,
      efficiency_factor: 3,
      aerobic_decoupling_pct: 1
    }.freeze

    # Terrain is trended alongside the fitness metrics, because a pace trend that
    # the terrain trend explains is not a fitness trend.
    TREND_METRICS = (SERIES_METRICS.keys + [ :elevation_gain_per_km ]).freeze

    ROUNDING = SERIES_METRICS.merge(elevation_gain_per_km: 1).freeze

    # A slope smaller than this per bucket is inside the noise of weather, route
    # and sample, and is not worth naming as a signal.
    NOTABLE_SLOPE = 2.0

    class << self
      def call(distance_bucket: nil, intensity: nil, days: nil, bucket_weeks: nil, server_context: nil)
        if distance_bucket.present? && distance_bucket != ANY && intensity.present?
          return failure(
            "distance_bucket and intensity are mutually exclusive: a series can be grouped by one or the " \
            "other, not both. Call the tool twice if you need each view."
          )
        end

        zone = runner_time_zone
        days = days_param(days, default: DEFAULT_DAYS, min: MIN_DAYS, max: MAX_DAYS)
        bucket_weeks = (bucket_weeks || DEFAULT_BUCKET_WEEKS).to_i.clamp(1, 12)
        window = TrainingWindow.ending(zone.today, days: days, zone: zone)

        filter = resolve_filter(distance_bucket, intensity, window)
        buckets = series_buckets(window, bucket_weeks, zone)
        series = buckets.map { |bucket| summarise(bucket, filter) }

        # Slopes are computed once, against each bucket's position in the full
        # series rather than its position among the usable ones. A skipped bucket
        # is a gap in time, and re-indexing around it would compress the x-axis
        # and overstate every trend.
        usable = series.each_with_index.select { |row, _index| row[:sufficient_sample] }
        slopes = TREND_METRICS.index_with { |column| slope_for(usable, column) }

        shaped(
          filter_applied: filter[:description],
          period: window.period.merge(bucket_weeks: bucket_weeks, buckets: series.size),
          training_context: TrainingContext.current(zone: zone).to_h,
          series: series,
          trend: trend(bucket_weeks, usable, slopes),
          race_markers: race_markers(window, filter),
          notable: notable_signals(window, series, filter, usable, slopes)
        )
      end

      private

      # Returns a hash carrying the predicate, the block that describes it on the
      # wire, and whether the data needed to apply it exists at all.
      def resolve_filter(distance_bucket, intensity, window)
        return intensity_filter(intensity, window) if intensity.present?
        return distance_filter(distance_bucket) if distance_bucket.present? && distance_bucket != ANY

        {
          available: true,
          predicate: ->(_activity) { true },
          description: { mode: "any", note: "All training runs, regardless of distance or intensity." }
        }
      end

      def distance_filter(key)
        bucket = DistanceBucket.find(key)

        {
          available: true,
          predicate: ->(activity) { bucket.covers?(activity.distance_meters) },
          description: { mode: "distance", distance_bucket: bucket.to_h, note: distance_note(bucket) }
        }
      end

      def distance_note(bucket)
        if bucket.standard?
          "Efforts within tolerance of #{bucket.label}. A watch never measures the nominal distance, " \
            "so the tolerance is what makes the band usable. Races are excluded from the series."
        else
          "#{bucket.label.capitalize}. Runs with no recorded distance are excluded."
        end
      end

      # An activity's intensity is the pace zone it spent most of its time in.
      #
      # The pipeline only derives pace_zone_distribution when threshold pace and
      # the zone boundaries are configured in its environment. Where they are not,
      # this mode has no data to work with, and the response says so explicitly
      # rather than returning an empty series that reads as "no such training".
      def intensity_filter(intensity, window)
        with_zones = window.activities.count { |a| a.pace_zone_distribution.present? }

        if with_zones.zero?
          return {
            available: false,
            predicate: ->(_activity) { false },
            description: {
              mode: "intensity",
              intensity: intensity,
              available: false,
              note: "Pace zone data is unavailable: none of the #{window.activities.size} activities in " \
                    "this window carry a pace zone distribution, so runs cannot be classified by " \
                    "intensity. This is a gap in the source data, not an absence of training at this " \
                    "intensity. Use distance_bucket instead."
            }
          }
        end

        {
          available: true,
          predicate: ->(activity) { dominant_pace_zone(activity) == intensity },
          description: {
            mode: "intensity",
            intensity: intensity,
            available: true,
            activities_classifiable: with_zones,
            note: "Runs whose largest share of time was spent in the #{intensity} pace zone. " \
                  "#{window.activities.size - with_zones} activities in the window carry no pace zone " \
                  "distribution and are excluded."
          }
        }
      end

      def dominant_pace_zone(activity)
        distribution = activity.pace_zone_distribution
        return nil if distribution.blank?

        distribution.max_by { |_zone, pct| pct.to_f }&.first
      end

      # Equal-width buckets walking back from the end of the window, so the most
      # recent bucket is always a full one and any clipping lands on the oldest.
      # A short final bucket at the recent end would be the one the client reads
      # the trend from.
      def series_buckets(window, bucket_weeks, zone)
        width = bucket_weeks * 7
        buckets = []
        last_day = window.to

        while last_day >= window.from
          first_day = [ last_day - (width - 1), window.from ].max
          buckets << TrainingWindow.between(first_day, last_day, zone: zone)
          last_day = first_day - 1
        end

        buckets.reverse
      end

      # Races are excluded here — TrainingWindow#mean already scopes to training
      # efforts — and reported as markers instead.
      def summarise(bucket, filter)
        matching = bucket.training_only.select { |activity| filter[:predicate].call(activity) }
        count = matching.size

        row = {
          from: bucket.from.to_s,
          to: bucket.to.to_s,
          activity_count: count,
          # Below the trend threshold the averages are still reported, because a
          # single run is a real data point, but the flag says not to read a
          # trend through it.
          sufficient_sample: count >= TrainingWindow::MIN_SAMPLE_FOR_TREND,
          total_distance_km: (matching.filter_map(&:distance_meters).sum / 1000.0).round(1),
          elevation_gain_per_km: gain_per_km(matching)
        }

        SERIES_METRICS.each do |column, precision|
          row[column] = mean_with_sample(matching.map(&column), precision: precision)[:value]
        end

        row
      end

      def gain_per_km(activities)
        measured = activities.select { |a| a.elevation_gain_meters && a.distance_meters.to_f.positive? }
        distance_km = measured.sum(&:distance_meters) / 1000.0
        return nil unless distance_km.positive?

        (measured.sum(&:elevation_gain_meters) / distance_km).round(1)
      end

      # Least-squares slope across the buckets carrying a sample, expressed per
      # bucket. A first-to-last difference would hand the entire trend to two
      # buckets and ignore everything between them.
      def slope_for(usable, column)
        linear_slope(usable.filter_map { |row, index| [ index, row[column] ] if row[column] })
      end

      def trend(bucket_weeks, usable, slopes)
        trend = {
          basis: "Least-squares slope per #{bucket_weeks}-week bucket, across the " \
                 "#{usable.size} #{'bucket'.pluralize(usable.size)} with at least " \
                 "#{TrainingWindow::MIN_SAMPLE_FOR_TREND} matching activities. " \
                 "A negative pace slope means the runner is getting faster.",
          buckets_used: usable.size
        }

        slopes.each do |column, slope|
          trend[:"#{column}_change_per_bucket"] = slope&.round(ROUNDING.fetch(column))
        end

        trend
      end

      # Every race in the window, whether or not it matches the filter. A
      # marathon result is context for a 10k progression, and flagging which
      # markers match the filter costs less than making the client call twice.
      def race_markers(window, filter)
        window.races.map do |activity|
          race = activity.race

          {
            date: window.local_date(activity).to_s,
            name: race.name,
            distance_km: activity.distance_meters ? (activity.distance_meters / 1000.0).round(2) : nil,
            nominal_distance_km: (race.distance_meters / 1000.0).round(1),
            result_time_seconds: race.result_time_seconds || activity.duration_seconds&.round,
            pace_per_km: activity.average_pace_per_km&.round(1),
            grade_adjusted_pace_per_km: activity.avg_grade_adjusted_pace_per_km&.round(1),
            matches_filter: filter[:predicate].call(activity)
          }
        end
      end

      def notable_signals(window, series, filter, usable, slopes)
        signals = []

        unless filter[:available]
          signals << filter[:description][:note]
          return signals
        end

        matched = series.sum { |row| row[:activity_count] }
        if matched.zero?
          signals << "No training runs in the last #{window.days} days match this filter."
          return signals
        end

        thin = series.count { |row| !row[:sufficient_sample] }
        if thin.positive?
          signals << "#{thin} of #{series.size} buckets hold fewer than " \
                     "#{TrainingWindow::MIN_SAMPLE_FOR_TREND} matching runs. They are reported rather than " \
                     "dropped, so the gaps in training stay visible."
        end

        signals.concat(divergence_signals(usable, slopes))

        if window.races.any?
          count = window.races.size
          signals << "#{count} race #{'effort'.pluralize(count)} in this window " \
                     "#{count == 1 ? 'is' : 'are'} excluded from the series and reported as race_markers."
        end

        signals
      end

      # The finding that justifies carrying both series: adjusted pace flat while
      # raw pace improves means the routes got flatter.
      def divergence_signals(usable, slopes)
        return [] if usable.size < 2

        signals = []
        raw = slopes[:average_pace_per_km]
        adjusted = slopes[:avg_grade_adjusted_pace_per_km]
        terrain = slopes[:elevation_gain_per_km]

        if adjusted && adjusted.abs >= NOTABLE_SLOPE
          direction = adjusted.negative? ? "faster" : "slower"
          signals << "Grade-adjusted pace is trending #{adjusted.abs.round(1)}s/km #{direction} per bucket " \
                     "across #{usable.size} buckets."
        end

        if raw && adjusted && (raw - adjusted).abs >= NOTABLE_SLOPE
          signals << "The raw and grade-adjusted pace trends disagree by " \
                     "#{(raw - adjusted).abs.round(1)}s/km per bucket, so the terrain changed over the " \
                     "period. Read the grade-adjusted series."
        end

        if terrain && terrain.abs >= NOTABLE_SLOPE
          signals << "Climbing per kilometre is trending #{terrain.round(1)}m/km per bucket, " \
                     "which is a change of routes rather than of fitness."
        end

        signals
      end
    end
  end
end
