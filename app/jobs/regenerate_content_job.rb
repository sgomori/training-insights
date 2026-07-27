# Regenerates the site's pre-generated content after a successful ingestion.
#
# The trigger point is wired now; the generation itself lands with the website.
# Content is produced by an Anthropic call at the client layer — never inside an
# MCP tool, which stays deterministic.
class RegenerateContentJob < ApplicationJob
  queue_as :default

  def perform(activity_id)
    activity = Activity.find_by(id: activity_id)
    return if activity.nil?

    Rails.logger.info("Content regeneration queued for activity #{activity.id}")
  end
end
