# One lap within an activity. Laps arrive as an ordered array carrying no
# identifiers, so `lap_index` — the position in that array — is the key that
# makes a replayed payload update laps in place rather than appending a set.
class ActivityLap < ApplicationRecord
  belongs_to :activity, inverse_of: :activity_laps

  validates :lap_index, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 },
    uniqueness: { scope: :activity_id }
end
