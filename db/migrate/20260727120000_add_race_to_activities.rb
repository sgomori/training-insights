class AddRaceToActivities < ActiveRecord::Migration[8.1]
  def change
    # Nullable and additive: existing rows stay valid, and the column can be
    # backfilled by linking races after the fact.
    #
    # Unique, because exactly one activity ran a given race. A race-day morning
    # may hold a warmup jog as well, but only the race effort itself links.
    #
    # Nullified rather than restricted on delete: removing a race entered in
    # error should unlink the activity, never block the delete and never take
    # the activity with it.
    add_reference :activities, :race,
      null: true,
      index: { unique: true },
      foreign_key: { on_delete: :nullify }
  end
end
