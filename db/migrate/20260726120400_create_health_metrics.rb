class CreateHealthMetrics < ActiveRecord::Migration[8.1]
  # Daily health values arriving from Garmin CSV exports via n8n. The four
  # metric types carry different keys, so the payload is stored as JSONB rather
  # than as a sparse wide table.
  #
  # Unlike the activity payload — whose shape fit-pipeline owns — this endpoint's
  # contract is defined here. The expected keys per type are:
  #
  #   sleep       sleep_duration_seconds, sleep_score, deep_sleep_seconds,
  #               light_sleep_seconds, rem_sleep_seconds, awake_seconds
  #   hrv         hrv_ms, hrv_status
  #   weight      weight_kg, body_fat_pct
  #   resting_hr  resting_hr_bpm
  #
  # The n8n workflow must normalise its CSV columns to these names.
  def change
    create_table :health_metrics do |t|
      t.date :recorded_date, null: false
      t.string :metric_type, null: false
      t.string :source
      t.datetime :processed_at
      t.jsonb :measurements, null: false, default: {}

      t.timestamps
    end

    add_index :health_metrics, [ :recorded_date, :metric_type ], unique: true
    add_index :health_metrics, :measurements, using: :gin

    # Stored generated columns for the handful of values MCP tools actually
    # filter and sort on. This keeps those queries indexable without flattening
    # the whole payload into columns.
    add_column :health_metrics, :sleep_score, :integer,
      as: "((measurements ->> 'sleep_score')::integer)", stored: true
    add_column :health_metrics, :hrv_ms, :float,
      as: "((measurements ->> 'hrv_ms')::double precision)", stored: true
    add_column :health_metrics, :weight_kg, :float,
      as: "((measurements ->> 'weight_kg')::double precision)", stored: true
    add_column :health_metrics, :resting_hr_bpm, :integer,
      as: "((measurements ->> 'resting_hr_bpm')::integer)", stored: true

    add_index :health_metrics, :recorded_date
  end
end
