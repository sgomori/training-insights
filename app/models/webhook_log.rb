# A record of one webhook delivery attempt. Rejected deliveries are logged too —
# those are the ones worth having when an activity fails to appear.
class WebhookLog < ApplicationRecord
  STATUSES = %w[created updated rejected failed].freeze

  belongs_to :record, polymorphic: true, optional: true

  validates :endpoint, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :most_recent_first, -> { order(created_at: :desc) }
  scope :failures, -> { where(status: %w[rejected failed]) }
end
