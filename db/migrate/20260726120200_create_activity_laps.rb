class CreateActivityLaps < ActiveRecord::Migration[8.1]
  def change
    create_table :activity_laps do |t|
      t.references :activity, null: false, foreign_key: true
      t.integer :lap_index, null: false

      t.datetime :started_at
      t.float :distance_meters
      t.float :duration_seconds
      t.integer :average_heart_rate
      t.integer :max_heart_rate
      t.integer :average_cadence
      t.float :average_pace_per_km

      t.timestamps
    end

    # Laps arrive as an ordered array with no identifiers of their own, so the
    # position within that array is the key. This is what makes a replayed
    # payload update laps in place instead of appending a second set.
    add_index :activity_laps, [ :activity_id, :lap_index ], unique: true
  end
end
