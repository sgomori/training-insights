class CreateRunners < ActiveRecord::Migration[8.1]
  def change
    create_table :runners do |t|
      t.string :name, null: false
      t.string :timezone, null: false, default: "America/Toronto"

      # Physiological configuration. These mirror the values the pipeline uses to
      # compute zone distributions and load, and are kept here so MCP tools can
      # report the thresholds a number was derived against.
      t.integer :threshold_heart_rate
      t.integer :resting_heart_rate
      t.integer :max_heart_rate

      # Pace zone boundaries in seconds per kilometre. Lower is faster.
      t.integer :threshold_pace_per_km
      t.integer :pace_zone_easy
      t.integer :pace_zone_moderate
      t.integer :pace_zone_threshold

      t.text :bio

      t.timestamps
    end
  end
end
