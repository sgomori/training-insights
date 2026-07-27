class CreateActivities < ActiveRecord::Migration[8.1]
  def change
    create_table :activities do |t|
      # --- Envelope -------------------------------------------------------
      t.string :source, null: false
      t.string :source_file
      t.string :schema_version, null: false
      t.datetime :processed_at

      # --- Activity summary -----------------------------------------------
      t.datetime :started_at, null: false
      t.string :activity_type, null: false
      t.float :distance_meters
      t.float :duration_seconds
      t.float :moving_time_seconds
      t.float :elevation_gain_meters
      t.float :elevation_loss_meters
      t.integer :average_heart_rate
      t.integer :max_heart_rate
      t.integer :average_cadence
      t.integer :max_cadence
      t.integer :average_power
      t.integer :max_power
      t.integer :normalized_power
      t.integer :total_calories
      t.float :average_pace_per_km
      t.integer :temperature_celsius

      # Device-reported TSS, distinct from the pipeline's computed tss_score
      # below. The payload carries both and they are not interchangeable.
      t.float :device_training_stress_score

      # --- Computed metrics -------------------------------------------------
      # All nullable by design: the pipeline emits null when a required stream
      # is missing, and omits null fields from the payload entirely. Aggregations
      # must exclude nils rather than coercing them to zero.
      t.float :aerobic_decoupling_pct
      t.float :efficiency_factor
      t.integer :cardiac_drift_bpm
      t.float :tss_score
      t.float :rtss_score
      t.float :pace_cv
      t.float :trimp
      t.float :avg_grade_adjusted_pace_per_km
      t.float :grade_adjusted_efficiency_factor
      t.jsonb :hr_zone_distribution
      t.jsonb :pace_zone_distribution

      t.timestamps
    end

    # Idempotency key. The payload carries no stable source identifier and the
    # `file` name can be reused, so a delivery is identified by where it came
    # from and when the activity started.
    add_index :activities, [ :source, :started_at ], unique: true

    # Every analytical tool filters on time, and most filter on type.
    add_index :activities, :started_at
    add_index :activities, :activity_type
  end
end
