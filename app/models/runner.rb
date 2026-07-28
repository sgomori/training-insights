# The runner this deployment belongs to. Single-runner by design: there is
# exactly one row, and `Runner.current` is the only supported way to reach it.
# Multi-tenancy would be a schema change, not a rewrite of every call site.
class Runner < ApplicationRecord
  validates :name, presence: true
  validates :timezone, presence: true

  def self.current
    first
  end

  def self.current!
    first or raise ActiveRecord::RecordNotFound, "No runner configured. Seed one before ingesting activities."
  end

  # Every period boundary in every analysis is bounded by calendar days in this
  # zone, so a run started at 23:00 local lands on the day the runner ran it.
  # Falls back to UTC before a runner has been configured.
  def self.current_time_zone
    ActiveSupport::TimeZone[current&.timezone.presence || "UTC"] || ActiveSupport::TimeZone["UTC"]
  end

  # Pace zone boundaries in seconds per kilometre, slowest first. Lower is faster.
  def pace_zone_boundaries
    { easy: pace_zone_easy, moderate: pace_zone_moderate, threshold: pace_zone_threshold }
  end
end
