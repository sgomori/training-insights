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
    avg_grade_adjusted_pace_per_km { 352.0 }
    tss_score { 60.0 }
    efficiency_factor { 1.30 }
    grade_adjusted_efficiency_factor { 1.33 }
    aerobic_decoupling_pct { 4.0 }
    cardiac_drift_bpm { 8 }
    pace_cv { 0.09 }
    hr_zone_distribution { { "zone_1" => 20.0, "zone_2" => 60.0, "zone_3" => 20.0, "zone_4" => 0.0, "zone_5" => 0.0 } }
    pace_zone_distribution { { "easy" => 70.0, "moderate" => 25.0, "threshold" => 5.0, "hard" => 0.0 } }

    # An activity for which the pipeline could not derive the computed metrics,
    # because a required stream was missing.
    trait :without_computed_metrics do
      tss_score { nil }
      efficiency_factor { nil }
      grade_adjusted_efficiency_factor { nil }
      avg_grade_adjusted_pace_per_km { nil }
      aerobic_decoupling_pct { nil }
      cardiac_drift_bpm { nil }
      pace_cv { nil }
      hr_zone_distribution { nil }
      pace_zone_distribution { nil }
    end

    # A hilly route: the climbing costs 30s/km against the flat equivalent.
    trait :hilly do
      elevation_gain_meters { 400.0 }
      average_pace_per_km { 390.0 }
      avg_grade_adjusted_pace_per_km { 360.0 }
    end

    # A structured session: pace swings hard, so metrics that assume an even
    # effort do not apply.
    trait :interval_session do
      pace_cv { 0.29 }
      cardiac_drift_bpm { 30 }
    end
  end

  factory :runner do
    name { "Steve Gomori" }
    timezone { "America/Toronto" }
    threshold_heart_rate { 167 }
    resting_heart_rate { 48 }
    max_heart_rate { 185 }
  end

  factory :race do
    name { "Toronto Waterfront Marathon" }
    race_date { 8.weeks.from_now.to_date }
    distance_meters { 42_195 }
    status { "upcoming" }
  end

  factory :api_key do
    sequence(:name) { |n| "client-#{n}" }
    token_digest { ApiKey.digest(SecureRandom.hex(8)) }
  end
end
