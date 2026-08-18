# Rewrites the site's standing summary after a new activity arrives.
#
# The activity id is a trigger and nothing more. It is looked up only to confirm
# the run it refers to still exists, and never reaches the model — the summary is
# written from the same tools a visitor's question goes through, so there is one
# path to the training data rather than two.
#
# This is the eager half of the caching. The summary is on every page load, so it
# has to be warm before the first visitor; individual answers are not, and cache
# themselves lazily on first ask.
class RegenerateContentJob < ApplicationJob
  queue_as :default

  # Nobody is waiting on this one, which makes a retry the right answer to a
  # transient failure — unlike a chat turn, where the visitor has already been
  # told it went wrong.
  retry_on Anthropic::Errors::APIConnectionError,
           Anthropic::Errors::RateLimitError,
           Anthropic::Errors::InternalServerError,
           wait: :polynomially_longer, attempts: 3

  def perform(activity_id)
    return if Activity.find_by(id: activity_id).nil?

    Answers::Cache.write_content(Ai::Content.call(runner_name: Runner.current&.name))
  rescue Ai::Client::Error => e
    # The previous summary stays in place and stays readable; it is only out of
    # date by one run. Blanking it would be the worse failure.
    Rails.logger.error("Content regeneration failed: #{e.class}: #{e.message}")
  end
end
