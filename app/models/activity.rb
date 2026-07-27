# A single workout, as delivered by the ingestion pipeline.
#
# Every computed metric is nullable: the pipeline emits null when a required
# stream is missing, and omits null fields from the payload entirely. Callers
# aggregating these columns must exclude nils rather than coercing them to zero.
class Activity < ApplicationRecord
  has_many :activity_laps, -> { order(:lap_index) }, dependent: :destroy, inverse_of: :activity
  has_one :activity_stream, dependent: :destroy, inverse_of: :activity

  validates :source, presence: true
  validates :schema_version, presence: true
  validates :started_at, presence: true
  validates :activity_type, presence: true
  validates :started_at, uniqueness: { scope: :source }

  scope :chronological, -> { order(:started_at) }
  scope :most_recent_first, -> { order(started_at: :desc) }
  scope :starting_between, ->(from, to) { where(started_at: from..to) }
  scope :of_type, ->(type) { where(activity_type: type) }

  # Computed metrics the pipeline could not derive are null, not zero. Scope to
  # the ones that carry a value before averaging.
  scope :with_metric, ->(column) { where.not(column => nil) }

  def streams?
    activity_stream.present?
  end

  def laps?
    activity_laps.any?
  end
end
