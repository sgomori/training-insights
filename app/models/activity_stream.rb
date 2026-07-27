# Time-series samples for one activity, held as PostgreSQL arrays.
#
# Stream availability varies by device and sensor, so every column is optional
# and any of them may be nil. There are no positional columns and none may be
# added — see the migration for why.
class ActivityStream < ApplicationRecord
  belongs_to :activity, inverse_of: :activity_stream

  # The stream names this application understands, matching the keys the
  # pipeline sends. `enhanced_speed` and `enhanced_altitude` carry the
  # `enhanced_` prefix in the payload; reading `speed` or `altitude` gets nil.
  STREAM_NAMES = %i[
    heart_rate cadence enhanced_speed enhanced_altitude
    power distance temperature vertical_oscillation stance_time
  ].freeze

  def available_streams
    STREAM_NAMES.select { |name| public_send(name).present? }
  end

  def sample_count
    available_streams.filter_map { |name| public_send(name)&.size }.max
  end
end
