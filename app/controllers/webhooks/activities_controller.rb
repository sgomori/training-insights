module Webhooks
  class ActivitiesController < BaseController
    def create
      return reject_malformed_body if payload.nil?

      parsed = Ingestion::ActivityPayload.new(payload)

      unless parsed.valid?
        log_delivery(status: "rejected", source_file: parsed.source_file,
                     error_message: parsed.errors.join("; "))
        return render json: { errors: parsed.errors }, status: :unprocessable_content
      end

      result = Ingestion::ActivityWriter.new(parsed).call

      log_delivery(status: result.status.to_s, record: result.activity,
                   source_file: parsed.source_file)

      RegenerateContentJob.perform_later(result.activity.id)

      render json: { status: result.status, activity_id: result.activity.id }, status: :ok
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      log_delivery(status: "failed", source_file: parsed&.source_file, error_message: e.message)
      render json: { errors: [ e.message ] }, status: :unprocessable_content
    end
  end
end
