module Ingestion
  # Validates and normalises an inbound activity payload.
  #
  # The sender omits null-valued fields entirely rather than sending explicit
  # nulls, so absence is valid input for anything optional. Only the envelope
  # and the two non-nullable activity fields are required.
  class ActivityPayload
    # Listed explicitly rather than matched on the major version. An unknown
    # version is rejected outright so a shape change cannot be half-parsed into
    # a row that looks plausible; adding one here means someone read the diff.
    #
    # 1.1 adds activity.started_at_local and activity.utc_offset_seconds. Both
    # are accepted and discarded — the schema has nowhere to put them, and every
    # calendar boundary still derives from started_at in the runner's timezone.
    SUPPORTED_SCHEMA_VERSIONS = %w[1.0 1.1].freeze

    # Payload key => Activity column. `training_stress_score` is the device's
    # own TSS and is deliberately kept apart from the pipeline's computed
    # `tss_score`; they are not interchangeable.
    ACTIVITY_ATTRIBUTES = {
      "type" => :activity_type,
      "started_at" => :started_at,
      "distance_meters" => :distance_meters,
      "duration_seconds" => :duration_seconds,
      "moving_time_seconds" => :moving_time_seconds,
      "elevation_gain_meters" => :elevation_gain_meters,
      "elevation_loss_meters" => :elevation_loss_meters,
      "average_heart_rate" => :average_heart_rate,
      "max_heart_rate" => :max_heart_rate,
      "average_cadence" => :average_cadence,
      "max_cadence" => :max_cadence,
      "average_power" => :average_power,
      "max_power" => :max_power,
      "normalized_power" => :normalized_power,
      "total_calories" => :total_calories,
      "average_pace_per_km" => :average_pace_per_km,
      "temperature_celsius" => :temperature_celsius,
      "training_stress_score" => :device_training_stress_score
    }.freeze

    COMPUTED_ATTRIBUTES = %w[
      aerobic_decoupling_pct efficiency_factor cardiac_drift_bpm
      tss_score rtss_score pace_cv trimp
      avg_grade_adjusted_pace_per_km grade_adjusted_efficiency_factor
      hr_zone_distribution pace_zone_distribution
    ].freeze

    LAP_ATTRIBUTES = %w[
      started_at distance_meters duration_seconds
      average_heart_rate max_heart_rate average_cadence average_pace_per_km
    ].freeze

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
    def source_file = @raw["file"]
    def processed_at = @raw["processed_at"]
    def started_at = activity["started_at"]

    def activity = @raw["activity"].is_a?(Hash) ? @raw["activity"] : {}
    def computed_metrics = @raw["computed_metrics"].is_a?(Hash) ? @raw["computed_metrics"] : {}
    def laps = @raw["laps"].is_a?(Array) ? @raw["laps"] : []
    def streams = @raw["streams"].is_a?(Hash) ? @raw["streams"] : {}

    # Attributes for the Activity row, excluding the idempotency key.
    def activity_attributes
      attrs = { schema_version: schema_version, source_file: source_file, processed_at: processed_at }

      ACTIVITY_ATTRIBUTES.each do |key, column|
        next if column == :started_at

        attrs[column] = activity[key] if activity.key?(key)
      end

      COMPUTED_ATTRIBUTES.each do |key|
        attrs[key.to_sym] = computed_metrics[key] if computed_metrics.key?(key)
      end

      attrs
    end

    def lap_attributes
      laps.each_with_index.map do |lap, index|
        next unless lap.is_a?(Hash)

        lap.slice(*LAP_ATTRIBUTES).symbolize_keys.merge(lap_index: index)
      end.compact
    end

    def stream_attributes
      attrs = streams.slice(*ActivityStream::STREAM_NAMES.map(&:to_s)).symbolize_keys
      return {} if attrs.empty?

      attrs
    end

    private

    def validate
      if schema_version.blank?
        errors << "schema_version is required"
      elsif SUPPORTED_SCHEMA_VERSIONS.exclude?(schema_version)
        errors << "unsupported schema_version #{schema_version.inspect}"
      end

      errors << "source is required" if source.blank?
      errors << "activity is required" if @raw["activity"].blank?
      errors << "activity.started_at is required" if activity["started_at"].blank?
      errors << "activity.type is required" if activity["type"].blank?

      validate_started_at_parses
    end

    def validate_started_at_parses
      return if activity["started_at"].blank?

      Time.iso8601(activity["started_at"].to_s)
    rescue ArgumentError
      errors << "activity.started_at is not a valid ISO 8601 timestamp"
    end
  end
end
