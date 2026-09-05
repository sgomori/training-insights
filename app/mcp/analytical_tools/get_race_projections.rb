module AnalyticalTools
  # What the runner's recent efforts project to at a target distance.
  #
  # The gap this fills: "what could he run for a 5k right now?" has no honest
  # answer from the other tools. get_race_readiness measures a buildup, and a
  # marathon block measured against 5km reads as absurd. get_personal_records
  # spans the whole history, and a record two years old says nothing about
  # today. This tool takes the efforts that do say something — recent races and
  # the best recent complete efforts at the standard distances — and carries
  # each to the target with Riegel's model, stating what it crossed to get there.
  #
  # It returns several projections and no estimate. Which reference to trust is
  # the reasoning, and the reasoning belongs to the client: a race projects
  # directly but may be stale, a training effort is current but submaximal, and
  # the response carries what is needed to weigh one against the other.
  class GetRaceProjections < AnalyticalTool
    tool_name "get_race_projections"

    description <<~TEXT.strip
      Projects the runner's recent efforts to a target distance, so a question
      about what they could run now for a 5k, a 10k or a half marathon is
      answered from evidence rather than from a buildup or an all-time record.
      Takes each completed race of the last year and the best complete training
      effort at each standard distance in a recent window, carries each to every
      requested distance with Riegel's endurance model, and groups the results by
      target with the distance ratio each projection crossed banded for
      reliability. Every race reference also carries the aerobic signals from the
      month before it, against the current month, so a stale race can be read
      against current fitness. A race projects directly; a training effort is
      submaximal and its projection is a floor at moderate ratios. Returns no
      single estimate — the projections are for the caller to weigh.
    TEXT

    input_schema(
      properties: {
        distances: {
          type: "array",
          description: "Standard distances to project to. Defaults to all of them; an empty list means the same.",
          items: { type: "string", enum: DistanceBucket::STANDARD.map(&:key) }
        },
        distance_km: {
          type: "number",
          description: "A non-standard target distance in kilometres, projected alongside any standard ones.",
          minimum: 1
        },
        days: {
          type: "integer",
          description: "Window for training reference efforts, counting back from today. Defaults to 90. " \
                       "Races are looked back a fixed 365 days regardless.",
          minimum: 14,
          maximum: 365
        }
      },
      required: []
    )

    DEFAULT_DAYS = 90
    MIN_DAYS = 14
    MAX_DAYS = 365

    # A race a year old is still the most recent maximal effort, and the
    # fitness comparison beside it exists to correct for its age. Fixed rather
    # than tied to the training window, because narrowing the search for a
    # current training effort should not also discard the last race.
    RACE_LOOKBACK_DAYS = 365

    # The month before a race against the current month, on the same chronic
    # baseline the load state is computed over.
    FITNESS_WINDOW_DAYS = TrainingContext::CHRONIC_DAYS

    # Month-to-month noise in grade-adjusted efficiency factor is a percent or
    # two, so a change smaller than this is reported in the figures but not
    # raised as a signal.
    MATERIAL_EF_CHANGE_PCT = 2.0

    # A race inside the current window shares days with its own comparison. Past
    # this much overlap the comparison is mostly of a period with itself, and
    # the signal is withheld rather than hedged.
    MAX_OVERLAP_DAYS_FOR_SIGNAL = FITNESS_WINDOW_DAYS / 2

    Target = Struct.new(:key, :label, :distance_km, keyword_init: true) do
      def to_h = { key: key, label: label, distance_km: distance_km }
    end

    BASIS = <<~TEXT.squish
      Each reference effort is carried to each target with Riegel's endurance
      model, T2 = T1 * (D2 / D1) ** 1.06, from its elapsed time — a race from
      its recorded result over its nominal distance, a training effort from its
      recorded duration over its measured distance — so the two kinds of
      reference sit on the same basis. Every projection reports the distance
      ratio it crossed and a reliability band taken from the larger distance
      over the smaller, because the model degrades as the two distances
      separate. A race is a maximal effort and projects directly. A training
      effort is submaximal by design: at a close or wide ratio its projection
      is a floor on what the runner could do, but carried far upward the
      model's optimism can exceed the submaximal margin and the figure bounds
      nothing. Training references are the best complete effort within
      tolerance of each standard distance in the training window, ranked on
      grade-adjusted pace where the effort carries one and raw pace otherwise;
      hard_effort is true where more than #{MetricMath::HARD_ZONE_SHARE_PCT.round}% of the
      effort's duration was in heart rate zone 4 or above. No segment inside a
      longer run is considered, because no tool on this server reads into an
      activity's streams.
    TEXT

    class << self
      def call(distances: nil, distance_km: nil, days: nil, server_context: nil)
        zone = runner_time_zone
        targets = resolve_targets(distances, distance_km)
        return targets if targets.is_a?(MCP::Tool::Response)

        training_days = days_param(days, default: DEFAULT_DAYS, min: MIN_DAYS, max: MAX_DAYS)
        now = TrainingWindow.ending(zone.today, days: FITNESS_WINDOW_DAYS, zone: zone)
        races = recent_races(zone)
        race_references = races.filter_map { |race| race_reference(race, now, zone) }
        training_references = training_references(training_days, zone)
        by_target = by_target(targets, race_references, training_references)

        shaped(
          basis: BASIS,
          targets: targets.map(&:to_h),
          windows: windows(training_days, zone),
          reliability: reliability_reference,
          training_context: TrainingContext.current(zone: zone).to_h,
          current_fitness: fitness_side(now),
          reference_efforts: {
            races: race_references,
            training_efforts: training_references
          },
          by_target: by_target,
          notable: notable_signals(races, race_references, training_references, by_target, training_days)
        )
      end

      private

      def resolve_targets(distances, distance_km)
        buckets = requested_buckets(distances)
        return buckets if buckets.is_a?(MCP::Tool::Response)

        targets = buckets.map { |bucket| Target.new(key: bucket.key, label: bucket.label, distance_km: bucket.nominal_km) }
        if distance_km.present?
          km = distance_km.to_f.round(2)
          return failure("distance_km must be at least 1.") if km < 1

          targets << Target.new(key: "custom", label: "#{km}km", distance_km: km)
        end

        targets
      end

      def requested_buckets(distances)
        return DistanceBucket.standard if distances.blank?

        requested = Array(distances).map(&:to_s)
        unknown = requested - DistanceBucket::STANDARD.map(&:key)

        if unknown.any?
          return failure(
            "Unknown #{'distance'.pluralize(unknown.size)}: #{unknown.join(', ')}. " \
            "Standard distances are #{DistanceBucket::STANDARD.map(&:key).join(', ')}; " \
            "pass distance_km for any other."
          )
        end

        DistanceBucket.standard.select { |bucket| requested.include?(bucket.key) }
      end

      def windows(training_days, zone)
        {
          training_efforts: {
            days: training_days,
            from: (zone.today - (training_days - 1)).to_s,
            to: zone.today.to_s
          },
          races: {
            days: RACE_LOOKBACK_DAYS,
            from: (zone.today - (RACE_LOOKBACK_DAYS - 1)).to_s,
            to: zone.today.to_s
          }
        }
      end

      # The band vocabulary once, at the top, rather than repeated on every
      # projection. Each projection then carries the ratio and its band alone.
      def reliability_reference
        MetricInterpretation.describe(:projection_distance_ratio, value: nil).except(:value)
      end

      def recent_races(zone)
        Race.completed
          .includes(:activity)
          .where(race_date: (zone.today - (RACE_LOOKBACK_DAYS - 1))..zone.today)
          .to_a
      end

      # Nil for a race with no time, which the notable block names rather than
      # letting it vanish. Pace over the nominal distance is named as such: the
      # linked activity's own pace is over the distance the watch measured, and
      # the two are not to be differenced.
      def race_reference(race, now, zone)
        time = race_time(race)
        return nil if time.nil?

        distance_km = race.distance_meters / 1000.0
        activity = race.activity

        {
          reference: { kind: "race", name: race.name, date: race.race_date.to_s,
                       days_ago: (zone.today - race.race_date).to_i },
          distance_km: distance_km.round(2),
          time_seconds: time,
          pace_per_km_at_nominal_distance: (time / distance_km).round(1),
          measured_distance_km: activity&.distance_meters&.then { |m| (m / 1000.0).round(2) },
          measured_pace_per_km: activity&.average_pace_per_km&.round(1),
          grade_adjusted_pace_per_km: activity&.avg_grade_adjusted_pace_per_km&.round(1),
          elevation_gain_meters: activity&.elevation_gain_meters&.round,
          average_heart_rate: activity&.average_heart_rate,
          fitness_change_since: fitness_change_since(race, now, zone)
        }
      end

      def race_time(race)
        race.result_time_seconds || race.activity&.duration_seconds&.round
      end

      # Training efforts in the month before the race against the current
      # month. This is what lets a client discount a stale race: efficiency
      # factor rises with fitness and decoupling falls, so the sign of each
      # change says which way the projection leans.
      def fitness_change_since(race, now, zone)
        before = TrainingWindow.between(race.race_date - FITNESS_WINDOW_DAYS, race.race_date - 1, zone: zone)
        overlap = overlap_days(before, now)
        suppressed = {}

        block = {
          basis: fitness_basis(overlap),
          before_race: fitness_side(before),
          grade_adjusted_efficiency_factor_change_pct: mean_change(
            before, now, :grade_adjusted_efficiency_factor, suppressed, precision: 3
          ) { |from, to| percent_change(from, to) },
          aerobic_decoupling_change_pct_points: mean_change(
            before, now, :aerobic_decoupling_pct, suppressed, precision: 1
          ) { |from, to| (to - from).round(1) },
          # The race itself is left out of the current month's volume where the
          # two overlap, or the effort being projected would inflate the volume
          # it is compared against.
          weekly_km_change_pct: percent_change(weekly_km(before), weekly_km(now, excluding: race)),
          overlap_days: overlap
        }
        block[:suppressed] = suppressed if suppressed.any?
        block
      end

      def fitness_basis(overlap)
        parts = [
          "The #{FITNESS_WINDOW_DAYS} days before the race against the current #{FITNESS_WINDOW_DAYS} days " \
          "in current_fitness. Efficiency factor and decoupling are means over training efforts only, " \
          "as everywhere on this server; weekly_km counts every activity. Efficiency factor rises with " \
          "aerobic fitness and decoupling falls. The current window ends today, so it is a part-day short."
        ]
        if overlap.positive?
          parts << "The race is recent enough that the two windows share #{overlap} " \
                   "#{'day'.pluralize(overlap)}, so the comparison is partly of a period with itself " \
                   "and the current side carries the recovery from the race."
        end
        parts.join(" ")
      end

      def overlap_days(a, b)
        return 0 unless a.overlaps?(b)

        ([ a.to, b.to ].min - [ a.from, b.from ].max).to_i + 1
      end

      def fitness_side(window)
        {
          period: window.period,
          weekly_km: weekly_km(window),
          grade_adjusted_efficiency_factor: window.mean(:grade_adjusted_efficiency_factor, precision: 3),
          aerobic_decoupling_pct: window.mean(:aerobic_decoupling_pct, precision: 1)
        }
      end

      def weekly_km(window, excluding: nil)
        activities = window.activities
        activities = activities.reject { |activity| activity.race_id == excluding.id } if excluding
        (activities.filter_map(&:distance_meters).sum / 1000.0 / window.weeks).round(1)
      end

      # The same thin-sample rule compare_periods applies: a mean is only worth
      # differencing when both sides carry enough activities with the metric.
      def mean_change(before, now, column, suppressed, precision: 2)
        from = before.mean(column, precision: precision)
        to = now.mean(column, precision: precision)

        thin = []
        thin << "the month before the race (#{from[:sample_size]})" if from[:sample_size] < TrainingWindow::MIN_SAMPLE_FOR_TREND
        thin << "the current month (#{to[:sample_size]})" if to[:sample_size] < TrainingWindow::MIN_SAMPLE_FOR_TREND

        if thin.any?
          suppressed[column] = "Suppressed: #{thin.to_sentence} carried fewer than " \
                               "#{TrainingWindow::MIN_SAMPLE_FOR_TREND} training efforts with this metric."
          return nil
        end

        yield(from[:value], to[:value])
      end

      # Every standard distance is searched, not only the requested ones: a hard
      # 5k is evidence for a half-marathon projection, and the ratio band says
      # how much. One query spans the tolerance bands, which are disjoint, and
      # Ruby sorts the rows into buckets.
      def training_references(training_days, zone)
        from = zone.parse((zone.today - (training_days - 1)).to_s).beginning_of_day
        to = zone.parse(zone.today.to_s).end_of_day
        buckets = DistanceBucket.standard
        candidates = Activity.training_only
          .starting_between(from, to)
          .where(distance_meters: (buckets.map(&:min_km).min * 1000)..(buckets.map(&:max_km).max * 1000))
          .to_a

        buckets.filter_map do |bucket|
          attempts = candidates.select { |activity| bucket.covers?(activity.distance_meters) }
          paced = attempts.select(&:average_pace_per_km)
          best = paced.min_by { |activity| [ ranking_time(activity, bucket), activity.started_at ] }
          next nil if best.nil?

          training_reference(best, bucket, paced.size, attempts.size - paced.size, zone)
        end
      end

      # Ranked on grade-adjusted pace where the effort carries one: a downhill
      # 5k beating a flat one is the terrain, not the runner.
      def ranking_time(activity, bucket)
        actual_km = activity.distance_meters / 1000.0
        pace = activity.avg_grade_adjusted_pace_per_km || activity.average_pace_per_km

        riegel_time(pace * actual_km, from_km: actual_km, to_km: bucket.nominal_km)
      end

      # Elapsed time where the activity recorded one, so a training reference
      # projects on the same basis as a race. Pace times distance is moving
      # time, and a run with stops in it would otherwise project faster than
      # the same run raced.
      def training_reference(activity, bucket, paced, unpaced, zone)
        distance_km = activity.distance_meters / 1000.0
        date = activity.started_at.in_time_zone(zone).to_date

        {
          reference: { kind: "training_effort", distance_bucket: bucket.key, date: date.to_s,
                       days_ago: (zone.today - date).to_i },
          distance_km: distance_km.round(2),
          time_seconds: activity.duration_seconds&.round || (activity.average_pace_per_km * distance_km).round,
          time_basis: activity.duration_seconds ? "elapsed" : "moving, reconstructed from pace",
          moving_time_seconds: activity.moving_time_seconds&.round,
          pace_per_km: activity.average_pace_per_km.round(1),
          grade_adjusted_pace_per_km: activity.avg_grade_adjusted_pace_per_km&.round(1),
          ranked_on: activity.avg_grade_adjusted_pace_per_km ? "grade_adjusted_pace" : "pace",
          elevation_gain_meters: activity.elevation_gain_meters&.round,
          average_heart_rate: activity.average_heart_rate,
          time_above_zone_4_pct: hard_zone_share(activity.hr_zone_distribution)&.round(1),
          hard_effort: hard_effort?(activity.hr_zone_distribution),
          attempts_considered: paced,
          attempts_without_pace: unpaced
        }
      end

      # The answer to the question the tool exists for, one lookup per target:
      # every reference's projection to it, fastest first, with the reference
      # it came from and whether that reference was a maximal effort.
      def by_target(targets, race_references, training_references)
        references = race_references.map { |ref| [ ref, true ] } + training_references.map { |ref| [ ref, false ] }

        targets.map do |target|
          projections = references.map { |ref, maximal| projection(ref, maximal, target) }
            .sort_by { |p| p[:projected_time_seconds] }

          {
            target: target.key,
            label: target.label,
            distance_km: target.distance_km,
            reference_count: projections.size,
            spread_seconds: projections.size >= 2 ? projections.last[:projected_time_seconds] - projections.first[:projected_time_seconds] : nil,
            projections: projections
          }
        end
      end

      def projection(reference, maximal, target)
        from_km = reference[:distance_km]
        ratio = target.distance_km / from_km
        projected = riegel_time(reference[:time_seconds], from_km: from_km, to_km: target.distance_km)

        {
          reference: reference[:reference],
          maximal_effort: maximal,
          projected_time_seconds: projected.round,
          projected_pace_per_km: (projected / target.distance_km).round(1),
          distance_ratio: ratio.round(2),
          direction: ratio > 1 ? "to a longer distance" : (ratio < 1 ? "to a shorter distance" : "same distance"),
          reliability: reliability_band(ratio)
        }
      end

      # Banded on the larger distance over the smaller, from the unrounded
      # ratio: 5k to 10k and 10k to 5k are the same distance apart in the
      # model's terms and get the same band.
      def reliability_band(ratio)
        folded = ratio >= 1 ? ratio : 1.0 / ratio
        MetricInterpretation.band_label_for(MetricInterpretation::DEFINITIONS.fetch(:projection_distance_ratio), folded)
      end

      def notable_signals(races, race_references, training_references, by_target, training_days)
        signals = []
        signals.concat(coverage_signals(races, race_references, training_references, training_days))
        signals.concat(far_reference_signals(by_target))
        signals.concat(training_beats_race_signals(by_target))
        signals.concat(fitness_signals(race_references))
        signals.concat(training_effort_signals(training_references))
        signals
      end

      def coverage_signals(races, race_references, training_references, training_days)
        signals = []
        untimed = races.select { |race| race_time(race).nil? }

        if untimed.any?
          signals << "#{untimed.map(&:name).to_sentence} #{untimed.size == 1 ? 'has' : 'have'} no recorded " \
                     "time and no linked activity, so #{untimed.size == 1 ? 'it is' : 'they are'} not projected."
        end

        if race_references.empty? && training_references.empty?
          signals << "No reference effort exists: no timed race in the last #{RACE_LOOKBACK_DAYS} days and " \
                     "no training effort within tolerance of a standard distance in the last " \
                     "#{training_days} days. Nothing can be projected."
        elsif race_references.empty?
          signals << "No timed race in the last #{RACE_LOOKBACK_DAYS} days, so every projection rests on a " \
                     "submaximal training effort."
        elsif training_references.empty?
          signals << "No training effort within tolerance of a standard distance in the last " \
                     "#{training_days} days, so the projections rest on race results alone."
        end

        signals
      end

      # Only where no reference sits close to the target: the projections carry
      # their own bands, so a target with a close reference needs no signal.
      def far_reference_signals(by_target)
        by_target.filter_map do |entry|
          projections = entry[:projections]
          next nil if projections.empty? || projections.any? { |p| p[:reliability] == "close" }

          nearest = projections.min_by { |p| Math.log(p[:distance_ratio]).abs }
          "No reference within a close ratio of the #{entry[:label]}: the nearest is " \
            "#{describe_reference(nearest[:reference])} at a distance ratio of #{nearest[:distance_ratio]} " \
            "(#{nearest[:reliability]})."
        end
      end

      # The tool's premise made visible: a submaximal effort projecting faster
      # than a maximal one says fitness has moved since the race.
      def training_beats_race_signals(by_target)
        by_target.filter_map do |entry|
          race = entry[:projections].find { |p| p[:maximal_effort] }
          training = entry[:projections].find { |p| !p[:maximal_effort] }
          next nil if race.nil? || training.nil?
          next nil unless training[:projected_time_seconds] < race[:projected_time_seconds]

          gap = race[:projected_time_seconds] - training[:projected_time_seconds]
          "At the #{entry[:label]}, #{describe_reference(training[:reference])} projects #{gap} seconds " \
            "faster than #{describe_reference(race[:reference])}, despite being a submaximal effort."
        end
      end

      def describe_reference(reference)
        if reference[:kind] == "race"
          "the #{reference[:name]} (#{reference[:date]})"
        else
          "the #{reference[:distance_bucket]} training effort of #{reference[:date]}"
        end
      end

      # The signed change with its sample sizes, and the reading that efficiency
      # factor rises with fitness. Which way that leans a projection is left to
      # the client.
      def fitness_signals(race_references)
        race_references.filter_map do |race|
          change = race[:fitness_change_since]
          ef = change[:grade_adjusted_efficiency_factor_change_pct]
          next nil if ef.nil? || ef.abs < MATERIAL_EF_CHANGE_PCT
          next nil if change[:overlap_days] > MAX_OVERLAP_DAYS_FOR_SIGNAL

          before = change[:before_race][:grade_adjusted_efficiency_factor][:sample_size]
          decoupling = change[:aerobic_decoupling_change_pct_points]
          sentence = "Grade-adjusted efficiency factor over the current #{FITNESS_WINDOW_DAYS} days is " \
                     "#{ef.abs}% #{ef.positive? ? 'higher' : 'lower'} than in the #{FITNESS_WINDOW_DAYS} days " \
                     "before the #{race[:reference][:name]} (#{before} training efforts then). Efficiency " \
                     "factor rises with aerobic fitness."
          sentence += " Decoupling moved #{decoupling} points over the same windows." unless decoupling.nil?
          sentence += " The windows share #{change[:overlap_days]} days." if change[:overlap_days].positive?
          sentence
        end
      end

      def training_effort_signals(training_references)
        return [] if training_references.empty?

        judged = training_references.reject { |ref| ref[:hard_effort].nil? }
        signals = []

        if judged.any? && judged.none? { |ref| ref[:hard_effort] }
          signals << "No training reference spent more than #{MetricMath::HARD_ZONE_SHARE_PCT.round}% of its " \
                     "duration in heart rate zone 4 or above, so none was a hard session and every training " \
                     "projection is a submaximal floor at best."
        end

        unjudged = training_references.size - judged.size
        if unjudged.positive?
          signals << "#{unjudged} training #{'reference'.pluralize(unjudged)} #{unjudged == 1 ? 'carries' : 'carry'} " \
                     "no heart rate zone distribution, so whether #{unjudged == 1 ? 'it' : 'they'} " \
                     "#{unjudged == 1 ? 'was' : 'were'} a hard effort cannot be said."
        end

        signals
      end
    end
  end
end
