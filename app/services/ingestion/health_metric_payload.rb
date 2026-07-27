module Ingestion
  # Validates and normalises an inbound health metric payload.
  #
  # Unlike the activity contract, which fit-pipeline owns, this endpoint's shape
  # is defined by this application — see the health_metrics migration for the
  # expected keys per metric type. The n8n workflow normalises Garmin's CSV
  # columns to those names.
  class HealthMetricPayload
    SUPPORTED_SCHEMA_VERSIONS = %w[1.0].freeze

    attr_reader :errors

    def initialize(raw)
      @raw = raw.is_a?(Hash) ? raw : {}
      @errors = []
      validate
    end

    def valid?
      errors.empty?
    end

    def schema_version = @raw["schema_version"]
    def source = @raw["source"]
    def metric_type = @raw["metric_type"]
    def recorded_date = @raw["recorded_date"]
    def processed_at = @raw["processed_at"]
    def measurements = @raw["values"].is_a?(Hash) ? @raw["values"] : {}

    def attributes
      { source: source, processed_at: processed_at, measurements: measurements }
    end

    private

    def validate
      if schema_version.blank?
        errors << "schema_version is required"
      elsif SUPPORTED_SCHEMA_VERSIONS.exclude?(schema_version)
        errors << "unsupported schema_version #{schema_version.inspect}"
      end

      if metric_type.blank?
        errors << "metric_type is required"
      elsif HealthMetric::METRIC_TYPES.exclude?(metric_type)
        errors << "unknown metric_type #{metric_type.inspect}"
      end

      if recorded_date.blank?
        errors << "recorded_date is required"
      else
        begin
          Date.iso8601(recorded_date.to_s)
        rescue ArgumentError
          errors << "recorded_date is not a valid ISO 8601 date"
        end
      end

      errors << "values must be an object" unless @raw["values"].is_a?(Hash)
    end
  end
end
