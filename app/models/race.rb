# An upcoming or past race. Provides the anchor date and target that the race
# readiness analyses are computed against.
class Race < ApplicationRecord
  STATUSES = %w[upcoming completed cancelled].freeze

  # The effort that ran it, linked on ingestion. Nullified rather than cascaded:
  # deleting a race entered in error must not delete the run.
  has_one :activity, dependent: :nullify, inverse_of: :race

  validates :name, presence: true
  validates :race_date, presence: true
  validates :distance_meters, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :upcoming, -> { where(status: "upcoming").order(:race_date) }
  scope :completed, -> { where(status: "completed").order(race_date: :desc) }

  def self.next_race
    upcoming.where(race_date: Date.current..).first
  end

  def days_until
    return nil unless race_date

    (race_date - Date.current).to_i
  end
end
