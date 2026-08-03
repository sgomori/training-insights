module Webhooks
  class HealthMetricsController < BaseController
    def create
      return reject_malformed_body if payload.nil?

      parsed = Ingestion::HealthMetricPayload.new(payload)

      unless parsed.valid?
        log_delivery(status: "rejected", error_message: parsed.errors.join("; "))
        return render json: { errors: parsed.errors }, status: :unprocessable_content
      end

      result = Ingestion::HealthMetricWriter.new(parsed).call

      log_delivery(status: result.status.to_s, record: result.health_metric)

      render json: { status: result.status, health_metric_id: result.health_metric.id }, status: :ok
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      log_delivery(status: "failed", error_message: e.message)
      render json: { errors: [ e.message ] }, status: :unprocessable_content
    end
  end
end
