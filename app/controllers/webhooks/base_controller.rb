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

    before_action :mark_request_start
    before_action :authenticate!

    # An unanticipated exception is precisely the one worth having a record of.
    # Without this it bypasses log_delivery, so the delivery that failed leaves
    # no trace in webhook_logs and the only evidence is a stack trace in the
    # application log — which is where an ArgumentError from insert_all! hid
    # while the backfill stalled behind it.
    #
    # The error is re-raised rather than rendered: Rails' own handling gives the
    # 500 and the backtrace, and this endpoint has nothing more useful to say to
    # a sender than that the delivery did not land.
    rescue_from StandardError do |error|
      record_failure(error)
      raise error
    end

    private

    def mark_request_start
      @started = monotonic_now
    end

    # A logging failure must never replace the error it was trying to record.
    def record_failure(error)
      log_delivery(status: "failed",
                   source_file: payload.is_a?(Hash) ? payload["file"] : nil,
                   error_message: "#{error.class}: #{error.message}")
    rescue StandardError => e
      Rails.logger.error("Could not record the failed delivery: #{e.message}")
    end

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

    def reject_malformed_body
      log_delivery(status: "rejected", error_message: "malformed JSON body")
      render json: { errors: [ "request body must be a JSON object" ] },
        status: :unprocessable_content
    end

    # Every delivery attempt is logged, including rejected ones — those are the
    # entries worth having when an activity fails to appear.
    def log_delivery(status:, record: nil, source_file: nil, error_message: nil)
      WebhookLog.create!(
        endpoint: request.path,
        status: status,
        record: record,
        source_file: source_file,
        error_message: error_message,
        payload_digest: payload_digest,
        duration_ms: ((monotonic_now - @started) * 1000).round
      )
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
