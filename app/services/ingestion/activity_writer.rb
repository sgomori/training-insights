module Ingestion
  # Writes a validated activity payload, idempotently.
  #
  # A redelivery of the same activity updates the existing row rather than
  # creating a second one, and replaces its laps and stream instead of appending
  # to them. The whole write is one transaction, so a partial activity can never
  # be observed.
  class ActivityWriter
    Result = Struct.new(:activity, :status, keyword_init: true) do
      def created? = status == :created
      def updated? = status == :updated
    end

    def initialize(payload)
      @payload = payload
    end

    def call
      activity = Activity.find_or_initialize_by(
        source: @payload.source,
        started_at: @payload.started_at
      )
      status = activity.new_record? ? :created : :updated

      Activity.transaction do
        activity.assign_attributes(@payload.activity_attributes)
        activity.save!

        replace_laps(activity)
        replace_stream(activity)
      end

      Result.new(activity: activity, status: status)
    end

    private

    def replace_laps(activity)
      laps = @payload.lap_attributes
      return if laps.empty?

      activity.activity_laps.delete_all
      activity.activity_laps.insert_all!(
        laps.map { |lap| lap.merge(created_at: Time.current, updated_at: Time.current) }
      )
    end

    def replace_stream(activity)
      attrs = @payload.stream_attributes
      return if attrs.empty?

      stream = activity.activity_stream || activity.build_activity_stream
      stream.assign_attributes(attrs)
      stream.save!
    end
  end
end
