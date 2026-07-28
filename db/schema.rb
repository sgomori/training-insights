# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_27_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "activities", force: :cascade do |t|
    t.string "activity_type", null: false
    t.float "aerobic_decoupling_pct"
    t.integer "average_cadence"
    t.integer "average_heart_rate"
    t.float "average_pace_per_km"
    t.integer "average_power"
    t.float "avg_grade_adjusted_pace_per_km"
    t.integer "cardiac_drift_bpm"
    t.datetime "created_at", null: false
    t.float "device_training_stress_score"
    t.float "distance_meters"
    t.float "duration_seconds"
    t.float "efficiency_factor"
    t.float "elevation_gain_meters"
    t.float "elevation_loss_meters"
    t.float "grade_adjusted_efficiency_factor"
    t.jsonb "hr_zone_distribution"
    t.integer "max_cadence"
    t.integer "max_heart_rate"
    t.integer "max_power"
    t.float "moving_time_seconds"
    t.integer "normalized_power"
    t.float "pace_cv"
    t.jsonb "pace_zone_distribution"
    t.datetime "processed_at"
    t.bigint "race_id"
    t.float "rtss_score"
    t.string "schema_version", null: false
    t.string "source", null: false
    t.string "source_file"
    t.datetime "started_at", null: false
    t.integer "temperature_celsius"
    t.integer "total_calories"
    t.float "trimp"
    t.float "tss_score"
    t.datetime "updated_at", null: false
    t.index ["activity_type"], name: "index_activities_on_activity_type"
    t.index ["race_id"], name: "index_activities_on_race_id", unique: true
    t.index ["source", "started_at"], name: "index_activities_on_source_and_started_at", unique: true
    t.index ["started_at"], name: "index_activities_on_started_at"
  end

  create_table "activity_laps", force: :cascade do |t|
    t.bigint "activity_id", null: false
    t.integer "average_cadence"
    t.integer "average_heart_rate"
    t.float "average_pace_per_km"
    t.datetime "created_at", null: false
    t.float "distance_meters"
    t.float "duration_seconds"
    t.integer "lap_index", null: false
    t.integer "max_heart_rate"
    t.datetime "started_at"
    t.datetime "updated_at", null: false
    t.index ["activity_id", "lap_index"], name: "index_activity_laps_on_activity_id_and_lap_index", unique: true
    t.index ["activity_id"], name: "index_activity_laps_on_activity_id"
  end

  create_table "activity_streams", force: :cascade do |t|
    t.bigint "activity_id", null: false
    t.integer "cadence", array: true
    t.datetime "created_at", null: false
    t.float "distance", array: true
    t.float "enhanced_altitude", array: true
    t.float "enhanced_speed", array: true
    t.integer "heart_rate", array: true
    t.integer "power", array: true
    t.integer "sample_rate_seconds"
    t.float "stance_time", array: true
    t.integer "temperature", array: true
    t.datetime "updated_at", null: false
    t.float "vertical_oscillation", array: true
    t.index ["activity_id"], name: "index_activity_streams_on_activity_id", unique: true
  end

  create_table "api_keys", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_api_keys_on_token_digest", unique: true
  end

  create_table "health_metrics", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.virtual "hrv_ms", type: :float, as: "((measurements ->> 'hrv_ms'::text))::double precision", stored: true
    t.jsonb "measurements", default: {}, null: false
    t.string "metric_type", null: false
    t.datetime "processed_at"
    t.date "recorded_date", null: false
    t.virtual "resting_hr_bpm", type: :integer, as: "((measurements ->> 'resting_hr_bpm'::text))::integer", stored: true
    t.virtual "sleep_score", type: :integer, as: "((measurements ->> 'sleep_score'::text))::integer", stored: true
    t.string "source"
    t.datetime "updated_at", null: false
    t.virtual "weight_kg", type: :float, as: "((measurements ->> 'weight_kg'::text))::double precision", stored: true
    t.index ["measurements"], name: "index_health_metrics_on_measurements", using: :gin
    t.index ["recorded_date", "metric_type"], name: "index_health_metrics_on_recorded_date_and_metric_type", unique: true
    t.index ["recorded_date"], name: "index_health_metrics_on_recorded_date"
  end

  create_table "races", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "distance_meters", null: false
    t.string "name", null: false
    t.text "notes"
    t.date "race_date", null: false
    t.integer "result_time_seconds"
    t.string "status", default: "upcoming", null: false
    t.integer "target_time_seconds"
    t.datetime "updated_at", null: false
    t.index ["race_date"], name: "index_races_on_race_date"
    t.index ["status"], name: "index_races_on_status"
  end

  create_table "runners", force: :cascade do |t|
    t.text "bio"
    t.datetime "created_at", null: false
    t.integer "max_heart_rate"
    t.string "name", null: false
    t.integer "pace_zone_easy"
    t.integer "pace_zone_moderate"
    t.integer "pace_zone_threshold"
    t.integer "resting_heart_rate"
    t.integer "threshold_heart_rate"
    t.integer "threshold_pace_per_km"
    t.string "timezone", default: "America/Toronto", null: false
    t.datetime "updated_at", null: false
  end

  create_table "webhook_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.string "endpoint", null: false
    t.text "error_message"
    t.string "payload_digest"
    t.bigint "record_id"
    t.string "record_type"
    t.string "source_file"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_webhook_logs_on_created_at"
    t.index ["record_type", "record_id"], name: "index_webhook_logs_on_record"
    t.index ["status"], name: "index_webhook_logs_on_status"
  end

  add_foreign_key "activities", "races", on_delete: :nullify
  add_foreign_key "activity_laps", "activities"
  add_foreign_key "activity_streams", "activities"
end
