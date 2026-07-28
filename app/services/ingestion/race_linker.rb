module Ingestion
  # Links an activity to the race it ran.
  #
  # Nothing in the source data marks a race. The FIT session message carries
  # `sport`, and its `sub_sport` companion enumerates terrain — road, trail,
  # track — not intent; the "race" label runners see in Garmin Connect is
  # applied there after upload and never reaches the file. So the link is
  # derived from the race calendar instead: the runner registers a race in
  # advance, and the effort that ran it is matched on date.
  #
  # Deliberately source-agnostic. It knows about dates and distances, nothing
  # about where the activity came from.
  class RaceLinker
    # Race morning usually holds a warmup jog as well as the race, so a date
    # match alone is ambiguous. The closest activity by distance wins, and only
    # within this tolerance — a 3km shakeout must never be recorded as the
    # marathon it preceded. Fifteen percent is wide enough to absorb GPS drift
    # over a marathon and narrow enough that no two standard distances overlap.
    DISTANCE_TOLERANCE = 0.15

    LINKABLE_STATUSES = %w[upcoming completed].freeze

    def self.call(activity) = new(activity).call

    # Links a race to an activity already in the database. Called when a race is
    # entered after the day it was run, which the ingestion path cannot catch.
    #
    # This is deliberately not a Race callback: the linker writes back to the
    # race to complete it, so a save-triggered callback would re-enter itself.
    def self.backfill(race)
      return nil unless LINKABLE_STATUSES.include?(race.status)

      activity = Activity
        .starting_between(*day_bounds(race.race_date))
        .find { |candidate| new(candidate).send(:within_tolerance?, race) }

      activity && call(activity)
    end

    def self.day_bounds(date)
      zone = Runner.current_time_zone
      [ zone.parse(date.to_s).beginning_of_day, zone.parse(date.to_s).end_of_day ]
    end

    def initialize(activity)
      @activity = activity
    end

    def call
      return nil unless @activity.distance_meters.to_f.positive?

      race = best_race
      return nil if race.nil?

      incumbent = race.activity
      return nil unless better_than?(incumbent, race)

      Race.transaction do
        incumbent.update!(race: nil) if incumbent && incumbent != @activity
        @activity.update!(race: race)
        # Elapsed rather than moving time: a race result is gun to finish, and
        # counts every second spent stopped at an aid station.
        race.update!(status: "completed", result_time_seconds: @activity.duration_seconds&.round)
      end

      race
    end

    private

    # The nearest race by distance among those scheduled for the day, ignoring
    # any the activity is too far off to plausibly be.
    def best_race
      Race
        .where(race_date: local_date, status: LINKABLE_STATUSES)
        .select { |race| within_tolerance?(race) }
        .min_by { |race| distance_error(race, @activity) }
    end

    def better_than?(incumbent, race)
      return true if incumbent.nil? || incumbent == @activity

      distance_error(race, @activity) < distance_error(race, incumbent)
    end

    def within_tolerance?(race)
      return false unless race.distance_meters.to_f.positive?

      distance_error(race, @activity) <= race.distance_meters * DISTANCE_TOLERANCE
    end

    def distance_error(race, activity)
      return Float::INFINITY if activity.distance_meters.nil?

      (activity.distance_meters - race.distance_meters).abs
    end

    def local_date
      @activity.started_at.in_time_zone(Runner.current_time_zone).to_date
    end
  end
end
