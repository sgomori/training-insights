# A daily health value derived from a Garmin CSV export via n8n.
#
# The four types carry different keys, so the payload lives in `measurements`
# (JSONB). The handful of values MCP tools filter and sort on are exposed as
# stored generated columns — see the migration for the expected key per type.
class HealthMetric < ApplicationRecord
  # Not an Active Record enum: an enum would generate a `HealthMetric.sleep`
  # class scope, which shadows Kernel#sleep.
  METRIC_TYPES = %w[sleep hrv weight resting_hr].freeze

  validates :recorded_date, presence: true
  validates :metric_type, presence: true, inclusion: { in: METRIC_TYPES }
  validates :recorded_date, uniqueness: { scope: :metric_type }

  scope :of_type, ->(type) { where(metric_type: type) }
  scope :recorded_between, ->(from, to) { where(recorded_date: from..to) }
  scope :chronological, -> { order(:recorded_date) }

  # CSV exports are manual and periodic, so gaps are normal. Callers must not
  # assume a contiguous series.
  def self.latest_of(type)
    of_type(type).order(recorded_date: :desc).first
  end
end
