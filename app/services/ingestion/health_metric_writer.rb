module Ingestion
  # Writes a validated health metric, idempotently on recorded_date and
  # metric_type. A re-export of the same day replaces the stored values.
  class HealthMetricWriter
    Result = Struct.new(:health_metric, :status, keyword_init: true) do
      def created? = status == :created
      def updated? = status == :updated
    end

    def initialize(payload)
      @payload = payload
    end

    def call
      metric = HealthMetric.find_or_initialize_by(
        recorded_date: @payload.recorded_date,
        metric_type: @payload.metric_type
      )
      status = metric.new_record? ? :created : :updated

      metric.assign_attributes(@payload.attributes)
      metric.save!

      Result.new(health_metric: metric, status: status)
    end
  end
end
