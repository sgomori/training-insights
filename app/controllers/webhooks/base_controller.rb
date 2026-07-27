module Webhooks
  # Shared authentication and logging for the ingestion endpoints.
  #
  # Inherits from ActionController::API rather than the app's ApplicationController:
  # these endpoints are machine-to-machine, so there is no session, no CSRF token,
  # and no view layer to carry along.
  class BaseController < ActionController::API
    # Params wrapping would nest the request body under a key derived from the
    # controller name — for ActivitiesController, "activity" — which silently
    # fabricates the very block the payload validator checks for.
    wrap_parameters false

    before_action :authenticate!

    private

    def authenticate!
      head :unauthorized unless authorized?
    end

    def authorized?
      expected = ENV["WEBHOOK_SECRET"]
      return false if expected.blank?

      ActiveSupport::SecurityUtils.secure_compare(presented_token, expected)
    end

    def presented_token
      request.headers["Authorization"].to_s.delete_prefix("Bearer ").strip
    end

    # Parsed from the raw body rather than from `params`, so nothing in Rails'
    # parameter pipeline can add, rename, or nest a key. Returns nil for a body
    # that is not a JSON object, which callers surface as 422.
    def payload
      return @payload if defined?(@payload)

      @payload = begin
        parsed = JSON.parse(request.raw_post.presence || "")
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end
    end

    def payload_digest
      OpenSSL::Digest::SHA256.hexdigest(request.raw_post.to_s)
    end

    def reject_malformed_body(started)
      log_delivery(status: "rejected", error_message: "malformed JSON body", started: started)
      render json: { errors: [ "request body must be a JSON object" ] },
        status: :unprocessable_content
    end

    # Every delivery attempt is logged, including rejected ones — those are the
    # entries worth having when an activity fails to appear.
    def log_delivery(status:, record: nil, source_file: nil, error_message: nil, started:)
      WebhookLog.create!(
        endpoint: request.path,
        status: status,
        record: record,
        source_file: source_file,
        error_message: error_message,
        payload_digest: payload_digest,
        duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      )
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
