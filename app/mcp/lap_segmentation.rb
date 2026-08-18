# Reads the shape of a single run out of its laps.
#
# This is the only place on the server that describes what happened *inside* an
# activity, and it works from the lap table rather than the raw streams. The
# distinction matters: laps arrive already normalised, one row per auto-lap or
# lap press, so nothing here reads into a stream.
#
# What that buys and what it costs. A session recorded with workout or manual
# laps segments exactly — every rep and every recovery is its own row. A session
# recorded on a 1 km auto-lap segments into kilometres, which shows that the pace
# changed and roughly where, but cannot recover a 400 m rep sitting inside one of
# them. The basis states which it worked from, so the difference is visible
# instead of assumed.
#
# Every threshold below is relative to the run's own median lap. An absolute pace
# boundary would classify an easy long run and a track session against the same
# yardstick, and be wrong about both.
#
# Three shapes it does not read, all deliberate rather than overlooked, and all
# of which degrade to loose phases — correct if verbose. None invents a
# structure.
#
# A ladder or pyramid collapses only its longest run of same-length repetitions,
# because the repeat detector walks forward and never re-segments. A rep the
# watch split across two consecutive laps reads as one long rep, which can push a
# set past the length-consistency check. And a set that fades far enough loses
# its last efforts: the reference is the median of every lap, so once a rep slows
# to within the tolerance band of it, that rep stops being a rep. Six that fade
# across the band read as four, then a steady stretch — which is what the laps
# say, if not what the runner set out to do.
module LapSegmentation
  # Two laps cannot describe a shape: any run has a first and last kilometre that
  # differ. Three is the fewest that can show a pattern rather than a difference.
  MINIMUM_LAPS = 3

  # A lap counts as faster or easier only when it clears both tolerances. The
  # relative one keeps the band proportionate on a slow run. The absolute one
  # carries the fast end, where six percent of a 4:00 kilometre is only 14
  # seconds and ordinary variation inside a race would otherwise read as
  # structure.
  RELATIVE_TOLERANCE = 0.06
  ABSOLUTE_TOLERANCE_SECONDS = 15.0

  # Two fast efforts are a pair, not a set. Three is where calling something
  # repeats stops being a stretch.
  MINIMUM_REPS = 3

  # Reps have to be recognisably the same effort repeated. Auto-lapped sessions
  # produce near-identical distances; hand-lapped ones drift by a few percent.
  # Beyond this the "reps" are just a run with several fast patches.
  REP_DISTANCE_RATIO = 1.4

  # Recoveries this uneven are not one fact, and reporting a median as though
  # they were would hide the interruption rather than describe it.
  RECOVERY_SPREAD_RATIO = 1.5

  # The distances watches actually lap at. Requiring the measured figure to land
  # on one of them is what separates an auto-lap from a hand-lapped set of equal
  # reps, which is otherwise the same sequence of numbers.
  AUTO_LAP_DISTANCES_KM = [ 0.5, 1.0, 1.60934, 2.0, 5.0 ].freeze

  # Two matching laps are a coincidence. Three are a setting.
  MINIMUM_FULL_LAPS_FOR_UNIFORMITY = 3

  Lap = Struct.new(:index, :distance_meters, :duration_seconds, :pace_per_km, :heart_rate, keyword_init: true)

  class << self
    # Returns the segmentation for one activity's laps. Never raises on thin or
    # missing data — an absent shape is a finding, and the caller renders it.
    def call(laps)
      usable = usable_laps(laps)
      skipped = laps.size - usable.size

      return unavailable(laps.size, usable.size) if usable.size < MINIMUM_LAPS

      reference = median(usable.map(&:pace_per_km))
      band = tolerance(reference)
      phases = label_ends(collapse_repeats(merge_runs(classify(usable, reference, band))))

      {
        shape: phases.size > 1 ? "structured" : "continuous",
        basis: basis(laps.size, skipped, uniform_lap_distance(laps)),
        reference_pace_per_km: reference.round(1),
        tolerance_seconds: band.round(1),
        phases: phases.map { |phase| present(phase) },
        explanation: explanation(phases, band)
      }
    end

    # The lap distance a watch was auto-lapping at, or nil where the laps were
    # pressed by hand.
    #
    # Three conditions, all required. Every lap but the last matches; the last is
    # meaningfully shorter, because a watch lapping every kilometre essentially
    # never stops on the boundary; and the figure lands on a distance watches
    # actually lap at. Without the third, five hand-pressed 1200 m blocks read as
    # a 1.2 km auto-lap and the response asserts something false about the watch.
    #
    # It fails closed. A treadmill or track run stopped exactly on a boundary
    # loses the caveat, which costs less than asserting the wrong one.
    def uniform_lap_distance(laps)
      usable = usable_laps(laps)
      return nil if usable.size <= MINIMUM_FULL_LAPS_FOR_UNIFORMITY

      full = usable[0..-2].map(&:distance_meters)
      return nil unless full.max <= full.min * 1.02
      return nil unless usable.last.distance_meters < full.min * 0.99

      measured = full.sum.fdiv(full.size) / 1000.0
      AUTO_LAP_DISTANCES_KM.find { |trigger| (measured - trigger).abs <= trigger * 0.02 }&.round(2)
    end

    private

    def tolerance(reference)
      [ reference * RELATIVE_TOLERANCE, ABSOLUTE_TOLERANCE_SECONDS ].max
    end

    def unavailable(total, usable)
      {
        shape: "unavailable",
        basis: basis(total, total - usable, nil),
        reference_pace_per_km: nil,
        tolerance_seconds: nil,
        phases: [],
        explanation: unavailable_explanation(total, usable)
      }
    end

    def unavailable_explanation(total, usable)
      if total.zero?
        "No laps were recorded for this activity, so its internal shape cannot be described. " \
        "The headline figures above still hold."
      elsif usable.zero?
        "None of the #{total} recorded #{'lap'.pluralize(total)} carried both a distance and a " \
        "duration, so the shape cannot be described."
      else
        "Only #{usable} usable #{'lap'.pluralize(usable)} #{usable == 1 ? 'was' : 'were'} recorded, " \
        "which is too few to describe a shape. #{MINIMUM_LAPS} is the minimum."
      end
    end

    # How the phases below should be read, stated where the reader is deciding
    # how to read them rather than buried among the notable signals.
    def basis(total, skipped, uniform_km)
      text = +"#{total} #{'lap'.pluralize(total)} recorded"
      text << ", #{skipped} skipped for missing distance or duration" if skipped.positive?
      text << "."

      if uniform_km
        text << " They are a uniform #{uniform_km} km, so the watch was lapping automatically: the " \
                "phases are groups of #{uniform_km} km splits, and an effort shorter than that sits " \
                "inside one of them and cannot be separated out."
      elsif total - skipped >= MINIMUM_LAPS
        text << " The lap lengths vary, so these are the efforts as they were lapped rather than " \
                "even splits."
      end

      text
    end

    # Distance and duration are what the classification runs on, so a lap missing
    # either is dropped rather than guessed at. The stored per-lap pace is
    # preferred where present because it is what the pipeline computed; deriving
    # it is the fallback, not the default.
    def usable_laps(laps)
      laps.filter_map do |lap|
        distance = lap.distance_meters
        duration = lap.duration_seconds
        next if distance.nil? || duration.nil? || distance <= 0 || duration <= 0

        Lap.new(
          index: lap.lap_index,
          distance_meters: distance,
          duration_seconds: duration,
          pace_per_km: lap.average_pace_per_km || (duration / (distance / 1000.0)),
          heart_rate: lap.average_heart_rate
        )
      end
    end

    # The median, not the mean: a set of short recoveries drags a mean toward
    # them and would reclassify the steady running around them as "faster".
    def median(values)
      sorted = values.sort
      middle = sorted.size / 2
      sorted.size.odd? ? sorted[middle] : ((sorted[middle - 1] + sorted[middle]) / 2.0)
    end

    def classify(laps, reference, band)
      laps.map do |lap|
        kind =
          if lap.pace_per_km < reference - band then :faster
          elsif lap.pace_per_km > reference + band then :easier
          else :steady
          end

        { kind: kind, laps: [ lap ] }
      end
    end

    def merge_runs(classified)
      classified.each_with_object([]) do |entry, merged|
        if merged.last && merged.last[:kind] == entry[:kind]
          merged.last[:laps].concat(entry[:laps])
        else
          merged << entry
        end
      end
    end

    # Finds the longest alternating stretch of reps and collapses it into one
    # repeats phase. A workout is described by its structure — six by one
    # kilometre — not by twelve phases the reader has to reassemble.
    def collapse_repeats(phases)
      best = longest_alternation(phases)
      return phases unless best

      first, last = best
      last += 1 if absorbable_tail?(phases, first, last)

      reps = phases[first..last].select { |phase| phase[:kind] == :faster }
      recoveries = phases[first..last].reject { |phase| phase[:kind] == :faster }

      phases[0...first] + [ { kind: :repeats, reps: reps, recoveries: recoveries } ] + phases[(last + 1)..]
    end

    # An alternation ends on a rep by construction, which strands the recovery
    # after the final one as a phase of its own. Absorb it — but only if it is
    # recognisably one of the recoveries the set has already shown.
    #
    # The bound matters more than it looks. When a set fades enough that its last
    # efforts drift back inside the tolerance band, they stop classifying as reps
    # and merge with the recoveries around them into one long steady phase.
    # Absorbing that unbounded reported a twelve-minute recovery among
    # sixty-second ones, which is not a recovery and not what happened.
    def absorbable_tail?(phases, first, last)
      candidate = phases[last + 1]
      return false unless recovery?(candidate)

      # Running to the end of the activity makes it a cooldown, not a recovery.
      return false unless phases[last + 2]

      established = phases[first..last].reject { |phase| phase[:kind] == :faster }
      return false if established.empty?

      total_duration(candidate[:laps]) <= median(established.map { |phase| total_duration(phase[:laps]) }) * 2
    end

    # Anything that is not another rep separates two of them.
    #
    # This used to require the connector to be classified `easier`, which failed
    # on the ordinary case. On an interval session the lap paces are bimodal with
    # roughly equal counts either side, so the median lands *inside* the recovery
    # cluster and every recovery classifies `steady`. The set only collapsed when
    # the recoveries were slower than the warmup — that is, walked. A runner who
    # jogs them got twelve loose phases and no repeats at all.
    def recovery?(phase)
      phase && phase[:kind] != :faster
    end

    # Walks every maximal alternation that starts and ends on a rep, and returns
    # the bounds of the one carrying the most.
    def longest_alternation(phases)
      best = nil
      best_reps = 0

      phases.each_index do |start|
        next unless phases[start][:kind] == :faster

        finish = start
        finish += 2 while recovery?(phases[finish + 1]) && phases[finish + 2]&.dig(:kind) == :faster

        reps = phases[start..finish].select { |phase| phase[:kind] == :faster }
        next if reps.size < MINIMUM_REPS
        next unless similar_distances?(reps)
        next unless reps.size > best_reps

        best = [ start, finish ]
        best_reps = reps.size
      end

      best
    end

    def similar_distances?(reps)
      distances = reps.map { |phase| total_distance(phase[:laps]) }
      distances.max <= distances.min * REP_DISTANCE_RATIO
    end

    # A single phase either side of the repeats is named for where it sits. Two
    # or more are not: a run that goes easy, hard, easy before the reps has a
    # shape of its own, and calling all of it a warmup would flatten it.
    def label_ends(phases)
      index = phases.index { |phase| phase[:kind] == :repeats }
      return phases unless index

      phases[0][:kind] = :warmup if index == 1 && phases[0][:kind] != :faster
      phases[-1][:kind] = :cooldown if index == phases.size - 2 && phases[-1][:kind] != :faster
      phases
    end

    def present(phase)
      return present_repeats(phase) if phase[:kind] == :repeats

      laps = phase[:laps]
      {
        kind: phase[:kind].to_s,
        laps: phase_range(laps),
        lap_count: laps.size,
        distance_km: (total_distance(laps) / 1000.0).round(2),
        duration_seconds: total_duration(laps).round,
        pace_per_km: weighted_pace(laps).round(1),
        pace_spread_seconds: pace_spread(laps),
        average_heart_rate: average_heart_rate(laps),
        heart_rate_from_laps: partial_heart_rate_count(laps)
      }.compact
    end

    def present_repeats(phase)
      reps = phase[:reps]
      recoveries = phase[:recoveries]
      rep_laps = reps.flat_map { |rep| rep[:laps] }

      # Per-rep paces in the order they were run. A set that faded and a set that
      # negative-split produce identical aggregates, and which of the two it was
      # is the first thing anyone asks about a workout.
      rep_paces = reps.map { |rep| weighted_pace(rep[:laps]).round(1) }
      recovery_durations = recoveries.map { |recovery| total_duration(recovery[:laps]) }

      {
        kind: "repeats",
        laps: phase_range(rep_laps + recoveries.flat_map { |recovery| recovery[:laps] }),
        reps: reps.size,
        rep_distance_km: (median(reps.map { |rep| total_distance(rep[:laps]) }) / 1000.0).round(2),
        rep_pace_per_km: weighted_pace(rep_laps).round(1),
        rep_paces_per_km: rep_paces,
        # Signed, last minus first: positive is a fade, negative a negative split.
        rep_pace_drift_seconds: (rep_paces.last - rep_paces.first).round(1),
        rep_pace_spread_seconds: (rep_paces.max - rep_paces.min).round(1),
        recovery_seconds: recovery_durations.any? ? median(recovery_durations).round : nil,
        recovery_seconds_range: uneven_recoveries(recovery_durations),
        recovery_distance_km: if recoveries.any?
                                (median(recoveries.map { |r| total_distance(r[:laps]) }) / 1000.0).round(2)
                              end,
        distance_km: ((total_distance(rep_laps) + recoveries.sum { |r| total_distance(r[:laps]) }) / 1000.0)
                       .round(2),
        average_heart_rate: average_heart_rate(rep_laps),
        heart_rate_from_laps: partial_heart_rate_count(rep_laps)
      }.compact
    end

    # A median recovery of 60 seconds says nothing about the one that ran to
    # five minutes, and the field name implies a single fact. Reported only when
    # the median would be hiding something.
    def uneven_recoveries(durations)
      return nil if durations.size < 2
      return nil if durations.max <= durations.min * RECOVERY_SPREAD_RATIO

      [ durations.min.round, durations.max.round ]
    end

    # Lap indexes are zero-based on the wire, matching what the watch wrote.
    def phase_range(laps)
      indexes = laps.map(&:index).minmax
      indexes.first == indexes.last ? indexes.first.to_s : indexes.join("-")
    end

    def total_distance(laps) = laps.sum(&:distance_meters)
    def total_duration(laps) = laps.sum(&:duration_seconds)

    # Distance-weighted, so a 200 m float inside a phase does not count for as
    # much as the kilometre beside it.
    def weighted_pace(laps) = total_duration(laps) / (total_distance(laps) / 1000.0)

    # How tightly the laps inside a phase held together, over the raw per-lap
    # paces. Note this aggregates a level below rep_pace_spread_seconds, which
    # spreads the reps' own weighted paces. Nil for a single lap, which has
    # nothing to spread against.
    def pace_spread(laps)
      return nil if laps.size < 2

      (laps.map(&:pace_per_km).max - laps.map(&:pace_per_km).min).round(1)
    end

    # Duration-weighted. An unweighted mean of per-lap averages lets a 200 m
    # float count for as much as the kilometre beside it, which on a warmup phase
    # is worth ten beats a minute.
    def average_heart_rate(laps)
      carrying = laps.select(&:heart_rate)
      return nil if carrying.empty?

      (carrying.sum { |lap| lap.heart_rate * lap.duration_seconds } / carrying.sum(&:duration_seconds)).round
    end

    # Only when some laps were missing a reading. A bare figure over five laps
    # and a bare figure over one of them are not the same claim.
    def partial_heart_rate_count(laps)
      carrying = laps.count(&:heart_rate)
      carrying if carrying.positive? && carrying < laps.size
    end

    # Emitted whether or not there is anything to explain, so a client can tell a
    # run with nothing to say about it from one whose key it misremembered.
    def explanation(phases, band)
      return nil unless phases.one?

      spread = pace_spread(phases.first[:laps])
      return "The laps hold one pace throughout, so the run reads as a single continuous effort." if
        spread.nil? || spread <= band

      "No lap sits far enough from the run's median to separate out, so it reads as continuous. The " \
      "laps still range over #{spread.round} seconds per kilometre, which is what an alternation too " \
      "small to cross the threshold looks like — cruise intervals and surges both do this."
    end
  end
end
