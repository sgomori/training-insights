FactoryBot.define do
  factory :activity do
    source { "garmin_fit" }
    schema_version { "1.0" }
    sequence(:started_at) { |n| 1.day.ago - n.hours }
    activity_type { "running" }
    distance_meters { 10_000.0 }
    duration_seconds { 3_600.0 }
    elevation_gain_meters { 80.0 }
    average_heart_rate { 145 }
    average_pace_per_km { 360.0 }
    tss_score { 60.0 }
    efficiency_factor { 1.30 }
    aerobic_decoupling_pct { 4.0 }
    cardiac_drift_bpm { 8 }
    hr_zone_distribution { { "zone_1" => 20.0, "zone_2" => 60.0, "zone_3" => 20.0, "zone_4" => 0.0, "zone_5" => 0.0 } }
    pace_zone_distribution { { "easy" => 70.0, "moderate" => 25.0, "threshold" => 5.0, "hard" => 0.0 } }

    # An activity for which the pipeline could not derive the computed metrics,
    # because a required stream was missing.
    trait :without_computed_metrics do
      tss_score { nil }
      efficiency_factor { nil }
      aerobic_decoupling_pct { nil }
      cardiac_drift_bpm { nil }
      hr_zone_distribution { nil }
      pace_zone_distribution { nil }
    end
  end

  factory :runner do
    name { "Steve Gomori" }
    timezone { "America/Toronto" }
    threshold_heart_rate { 167 }
    resting_heart_rate { 48 }
    max_heart_rate { 185 }
  end

  factory :api_key do
    sequence(:name) { |n| "client-#{n}" }
    token_digest { ApiKey.digest(SecureRandom.hex(8)) }
  end
end
