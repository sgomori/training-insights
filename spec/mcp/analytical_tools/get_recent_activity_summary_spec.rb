require "rails_helper"

RSpec.describe AnalyticalTools::GetRecentActivitySummary do
  subject(:payload) { described_class.call(**args).structured_content }

  let(:args) { { days: 28 } }
  let!(:runner) { create(:runner, timezone: "America/Toronto") }

  # A fixed "now" so period boundaries are deterministic.
  around do |example|
    travel_to(Time.utc(2026, 6, 15, 12, 0, 0)) { example.run }
  end

  describe "the period it reports on" do
    it "states the window, timezone and count so the response stands alone" do
      create(:activity, started_at: 2.days.ago)

      expect(payload[:period]).to include(
        days: 28,
        timezone: "America/Toronto",
        activity_count: 1
      )
      expect(payload[:period][:to]).to eq("2026-06-15")
      expect(payload[:period][:from]).to eq("2026-05-19")
    end

    it "excludes activities outside the window" do
      create(:activity, started_at: 5.days.ago)
      create(:activity, started_at: 60.days.ago)

      expect(payload[:period][:activity_count]).to eq(1)
    end
  end

  describe "volume" do
    it "aggregates distance and duration" do
      create(:activity, started_at: 2.days.ago, distance_meters: 10_000, duration_seconds: 3_600)
      create(:activity, started_at: 3.days.ago, distance_meters: 5_000, duration_seconds: 1_800)

      expect(payload[:volume]).to include(
        activity_count: 2,
        total_distance_km: 15.0,
        total_duration_hours: 1.5,
        longest_run_km: 10.0
      )
    end

    it "counts distinct days rather than activities, so rest days can be derived" do
      create(:activity, started_at: 2.days.ago.change(hour: 7))
      create(:activity, started_at: 2.days.ago.change(hour: 18))
      create(:activity, started_at: 4.days.ago)

      expect(payload[:volume][:activity_count]).to eq(3)
      expect(payload[:volume][:days_with_activity]).to eq(2)
    end
  end

  describe "training load" do
    it "reports load scoped to the requested period" do
      28.times { |i| create(:activity, started_at: i.days.ago, tss_score: 60.0) }

      load = payload[:training_load]
      expect(load[:total_tss]).to eq(1680.0)
      expect(load[:average_daily_tss]).to eq(60.0)
    end

    it "excludes activities with no TSS and says how many were missing" do
      create(:activity, started_at: 2.days.ago, tss_score: 50.0)
      create(:activity, :without_computed_metrics, started_at: 3.days.ago)

      load = payload[:training_load]
      expect(load[:total_tss]).to eq(50.0)
      expect(load[:activities_missing_tss]).to eq(1)
    end

    # The acute:chronic ratio describes the runner's present state, not the
    # requested window, so it lives in training_context and must not move when
    # the caller asks about a different period.
    it "keeps the acute:chronic ratio out of the period-scoped load block" do
      create(:activity, started_at: 2.days.ago)

      expect(payload[:training_load]).not_to have_key(:acute_chronic_ratio)
    end
  end

  describe "training context" do
    it "normalises chronic load to a weekly figure so the ratio sits near 1.0 for steady training" do
      # 60 TSS every day for 28 days: acute (7d) = 420, chronic weekly = 420.
      28.times { |i| create(:activity, started_at: i.days.ago, tss_score: 60.0) }

      context = payload[:training_context]
      expect(context[:acute_7d_tss]).to eq(420.0)
      expect(context[:chronic_weekly_tss]).to eq(420.0)
      expect(context.dig(:acute_chronic_ratio, :value)).to be_within(0.05).of(1.0)
      expect(context.dig(:acute_chronic_ratio, :band)).to eq("typical maintenance range")
    end

    it "reports a ratio above 1.0 when recent load spikes" do
      21.times { |i| create(:activity, started_at: (i + 7).days.ago, tss_score: 20.0) }
      7.times { |i| create(:activity, started_at: i.days.ago, tss_score: 100.0) }

      expect(payload[:training_context].dig(:acute_chronic_ratio, :value)).to be > 1.5
      expect(payload[:training_context].dig(:acute_chronic_ratio, :band)).to eq("sharp load increase")
    end

    it "reports the same ratio regardless of the window the caller asked about" do
      28.times { |i| create(:activity, started_at: i.days.ago, tss_score: 60.0) }

      short = described_class.call(days: 7).structured_content
      long = described_class.call(days: 90).structured_content

      expect(short.dig(:training_context, :acute_chronic_ratio, :value))
        .to eq(long.dig(:training_context, :acute_chronic_ratio, :value))
    end

    it "flags a chronic baseline that has less than 28 days of history behind it" do
      create(:activity, started_at: 5.days.ago)

      context = payload[:training_context]
      expect(context[:sufficient_history_for_chronic_load]).to be(false)
      expect(context[:history_spans_days]).to eq(6)
      expect(context.dig(:acute_chronic_ratio, :caveats))
        .to include(a_string_matching(/not yet a true chronic load/))
      expect(payload[:notable]).to include(a_string_matching(/Only 6 days of history exist/))
    end

    it "accepts the chronic figure once enough history exists" do
      create(:activity, started_at: 40.days.ago)
      create(:activity, started_at: 2.days.ago)

      expect(payload[:training_context][:sufficient_history_for_chronic_load]).to be(true)
    end

    it "counts the consecutive training day streak and the days since the last run" do
      5.times { |i| create(:activity, started_at: i.days.ago) }

      context = payload[:training_context]
      expect(context[:consecutive_training_days]).to eq(5)
      expect(context[:days_since_last_activity]).to eq(0)
      expect(context[:rest_days_in_last_7]).to eq(2)
    end

    it "does not extend a streak across a rest day" do
      create(:activity, started_at: 0.days.ago)
      create(:activity, started_at: 1.day.ago)
      # No activity two days ago.
      create(:activity, started_at: 3.days.ago)

      expect(payload[:training_context][:consecutive_training_days]).to eq(2)
    end

    it "reports a streak that has already ended alongside the days since it did" do
      3.times { |i| create(:activity, started_at: (i + 4).days.ago) }

      context = payload[:training_context]
      expect(context[:consecutive_training_days]).to eq(3)
      expect(context[:days_since_last_activity]).to eq(4)
    end

    it "surfaces a long unbroken block as a notable signal" do
      9.times { |i| create(:activity, started_at: i.days.ago) }

      expect(payload[:notable]).to include(a_string_matching(/9 consecutive training days/))
    end

    it "carries the next race so a period can be read against what it is preparing for" do
      create(:activity, started_at: 2.days.ago)
      create(:race, name: "Toronto Waterfront", race_date: Date.new(2026, 7, 5),
        distance_meters: 42_195, status: "upcoming")

      expect(payload[:training_context][:next_race]).to include(
        name: "Toronto Waterfront", days_until: 20, distance_km: 42.2
      )
    end

    it "omits the race block entirely when nothing is scheduled" do
      create(:activity, started_at: 2.days.ago)

      expect(payload[:training_context]).not_to have_key(:next_race)
    end
  end

  describe "race efforts" do
    # A race is real work, so it belongs in volume and load. It is also a
    # maximal effort, so it must not sit in an average alongside easy runs.
    let!(:race) do
      create(:race, name: "Spring Half", race_date: Date.new(2026, 6, 7),
        distance_meters: 21_097, status: "completed")
    end

    let!(:raced) do
      create(:activity, started_at: Time.utc(2026, 6, 7, 13, 0), race: race,
        distance_meters: 21_140.0, duration_seconds: 5_400.0,
        efficiency_factor: 1.90, aerobic_decoupling_pct: 16.0, pace_cv: 0.04)
    end

    before do
      3.times { |i| create(:activity, started_at: (i + 1).days.ago, efficiency_factor: 1.30, aerobic_decoupling_pct: 4.0) }
    end

    it "excludes the race from the aerobic averages" do
      signals = payload[:aerobic_signals]

      expect(signals[:efficiency_factor][:value]).to eq(1.3)
      expect(signals[:aerobic_decoupling_pct][:value]).to eq(4.0)
      expect(signals[:efficiency_factor][:sample_size]).to eq(3)
    end

    it "states the basis so the exclusion is visible rather than silent" do
      expect(payload[:aerobic_signals][:basis]).to match(/1 race effort excluded/)
    end

    # An evenly paced race passes the steady-state filter, so the pace
    # variability guard would never have caught it.
    it "excludes the race even though its pacing looks like a steady effort" do
      expect(payload[:aerobic_signals][:cardiac_drift_bpm][:sample_size]).to eq(3)
    end

    it "still counts the race in volume and training load" do
      expect(payload[:volume][:activity_count]).to eq(4)
      expect(payload[:volume][:total_distance_km]).to eq(51.1)
      expect(payload[:training_load][:total_tss]).to eq(240.0)
    end

    it "names the race in the notable signals" do
      expect(payload[:notable]).to include(a_string_matching(/Raced Spring Half on 2026-06-07 \(21\.1km\)/))
    end

    it "does not also report the race as excluded for its pacing" do
      raced.update!(pace_cv: 0.35)

      expect(payload[:notable]).not_to include(a_string_matching(/highly variable pace/))
    end

    it "reports how long ago the last race was" do
      expect(payload[:training_context][:days_since_last_race]).to eq(8)
    end

    it "omits the field entirely when the runner has never raced" do
      raced.update!(race: nil)

      expect(payload[:training_context]).not_to have_key(:days_since_last_race)
    end
  end

  describe "terrain" do
    it "reports climbing per kilometre and bands the terrain" do
      create(:activity, started_at: 2.days.ago, distance_meters: 10_000, elevation_gain_meters: 100)
      create(:activity, started_at: 3.days.ago, distance_meters: 10_000, elevation_gain_meters: 50)

      terrain = payload[:terrain]
      expect(terrain[:total_elevation_gain_m]).to eq(150)
      expect(terrain[:elevation_gain_per_km][:value]).to eq(7.5)
      expect(terrain[:elevation_gain_per_km][:band]).to eq("gently rolling")
    end

    it "excludes activities missing either figure so they cannot drag the ratio toward flat" do
      create(:activity, started_at: 2.days.ago, distance_meters: 10_000, elevation_gain_meters: 400)
      create(:activity, started_at: 3.days.ago, distance_meters: 10_000, elevation_gain_meters: nil)

      terrain = payload[:terrain]
      expect(terrain[:elevation_gain_per_km][:value]).to eq(40.0)
      expect(terrain[:elevation_gain_per_km][:sample_size]).to eq(1)
      expect(terrain[:elevation_gain_per_km][:band]).to eq("hilly")
    end

    it "returns a null ratio rather than dividing by zero on an empty period" do
      expect(payload[:terrain][:elevation_gain_per_km][:value]).to be_nil
    end
  end

  describe "intensity distribution" do
    it "weights zone percentages by duration rather than averaging them" do
      # A 3-hour run entirely in zone 2 and a 1-hour run entirely in zone 4.
      # Duration-weighted this is 75/25; a naive mean of percentages gives 50/50.
      create(:activity, started_at: 2.days.ago, duration_seconds: 10_800,
        hr_zone_distribution: { "zone_2" => 100.0, "zone_4" => 0.0 })
      create(:activity, started_at: 3.days.ago, duration_seconds: 3_600,
        hr_zone_distribution: { "zone_2" => 0.0, "zone_4" => 100.0 })

      zones = payload[:intensity_distribution][:hr_zones_pct]
      expect(zones[:zones]["zone_2"]).to eq(75.0)
      expect(zones[:zones]["zone_4"]).to eq(25.0)
      expect(zones[:activities_contributing]).to eq(2)
    end

    it "keeps aggregated percentages summing to 100 across unequal durations" do
      3.times do |i|
        create(:activity, started_at: (i + 2).days.ago, duration_seconds: (i + 1) * 1_800)
      end

      zones = payload[:intensity_distribution][:hr_zones_pct][:zones]
      expect(zones.values.sum).to be_within(0.2).of(100.0)
    end

    it "ignores activities whose zone data the pipeline could not derive" do
      create(:activity, started_at: 2.days.ago, duration_seconds: 3_600,
        hr_zone_distribution: { "zone_2" => 100.0 })
      create(:activity, :without_computed_metrics, started_at: 3.days.ago, duration_seconds: 3_600)

      zones = payload[:intensity_distribution][:hr_zones_pct]
      expect(zones[:activities_contributing]).to eq(1)
      expect(zones[:zones]["zone_2"]).to eq(100.0)
    end

    it "returns no zones at all rather than a misleading zero when nothing qualifies" do
      create(:activity, :without_computed_metrics, started_at: 2.days.ago)

      expect(payload[:intensity_distribution][:hr_zones_pct]).to eq(
        zones: nil, activities_contributing: 0
      )
    end
  end

  describe "aerobic signals" do
    it "reports the sample size behind every average" do
      create(:activity, started_at: 2.days.ago, efficiency_factor: 1.30)
      create(:activity, started_at: 3.days.ago, efficiency_factor: 1.40)
      create(:activity, :without_computed_metrics, started_at: 4.days.ago)

      ef = payload[:aerobic_signals][:efficiency_factor]
      expect(ef[:value]).to eq(1.35)
      expect(ef[:sample_size]).to eq(2)
    end

    it "does not treat a missing metric as zero" do
      create(:activity, started_at: 2.days.ago, aerobic_decoupling_pct: 4.0)
      create(:activity, :without_computed_metrics, started_at: 3.days.ago)

      # Averaging nil as zero would give 2.0.
      expect(payload[:aerobic_signals][:aerobic_decoupling_pct][:value]).to eq(4.0)
    end

    it "reports pace and efficiency factor both raw and grade-adjusted" do
      create(:activity, :hilly, started_at: 2.days.ago, grade_adjusted_efficiency_factor: 1.40)

      signals = payload[:aerobic_signals]
      expect(signals[:average_pace_per_km][:value]).to eq(390.0)
      expect(signals[:avg_grade_adjusted_pace_per_km][:value]).to eq(360.0)
      expect(signals[:grade_adjusted_efficiency_factor][:value]).to eq(1.4)
      expect(signals[:avg_grade_adjusted_pace_per_km][:guidance]).to match(/flat-equivalent/)
    end

    it "leaves the grade-adjusted figures null when the pipeline had no altitude stream" do
      create(:activity, :without_computed_metrics, started_at: 2.days.ago)

      signals = payload[:aerobic_signals]
      expect(signals[:avg_grade_adjusted_pace_per_km][:value]).to be_nil
      expect(signals[:grade_adjusted_efficiency_factor][:sample_size]).to eq(0)
    end

    it "ships the shared reading guidance with every signal" do
      create(:activity, started_at: 2.days.ago)

      signals = payload[:aerobic_signals]
      expect(signals[:average_pace_per_km]).to include(
        unit: "seconds per kilometre", direction: "lower_is_faster"
      )
      expect(signals[:efficiency_factor][:direction]).to eq("higher_is_better")
      expect(signals[:aerobic_decoupling_pct][:direction]).to eq("lower_is_better")
      expect(signals[:aerobic_decoupling_pct][:guidance]).to be_present
    end

    it "classifies each value against its published band" do
      create(:activity, started_at: 2.days.ago, aerobic_decoupling_pct: 12.0, efficiency_factor: 1.30)

      signals = payload[:aerobic_signals]
      expect(signals[:aerobic_decoupling_pct][:band]).to eq("significant decoupling")
      expect(signals[:efficiency_factor][:band]).to eq("typical for a trained runner")
    end

    it "carries the reference bands so the client can reason numerically" do
      create(:activity, started_at: 2.days.ago)

      bands = payload[:aerobic_signals][:aerobic_decoupling_pct][:reference_bands]
      expect(bands).to include(a_hash_including(label: "well conditioned", max: 5.0))
    end
  end

  describe "contextual qualification of cardiac drift" do
    it "averages drift over steady-state efforts only" do
      create(:activity, started_at: 2.days.ago, cardiac_drift_bpm: 10, pace_cv: 0.08)
      create(:activity, started_at: 3.days.ago, cardiac_drift_bpm: 12, pace_cv: 0.10)
      create(:activity, :interval_session, started_at: 4.days.ago, cardiac_drift_bpm: 40)

      drift = payload[:aerobic_signals][:cardiac_drift_bpm]
      # Including the interval session would drag the mean to 20.7.
      expect(drift[:value]).to eq(11.0)
      expect(drift[:sample_size]).to eq(2)
    end

    it "says what it set aside and why" do
      create(:activity, started_at: 2.days.ago, cardiac_drift_bpm: 10, pace_cv: 0.08)
      create(:activity, :interval_session, started_at: 3.days.ago)

      caveats = payload[:aerobic_signals][:cardiac_drift_bpm][:caveats]
      expect(caveats).to include(a_string_matching(/steady-state efforts only/))
      expect(caveats).to include(a_string_matching(/1 activity excluded as non-steady-state/))
    end

    it "excludes activities whose pace variability could not be derived" do
      create(:activity, started_at: 2.days.ago, cardiac_drift_bpm: 10, pace_cv: nil)

      drift = payload[:aerobic_signals][:cardiac_drift_bpm]
      expect(drift[:value]).to be_nil
      expect(drift[:caveats]).to include(a_string_matching(/pace variability could not be derived/))
    end

    it "surfaces structured sessions as a notable signal" do
      create_list(:activity, 3, :interval_session)

      expect(payload[:notable]).to include(a_string_matching(/highly variable pace/))
    end
  end

  describe "comparison against the preceding period" do
    it "reports a negative pace delta when the runner got faster" do
      4.times { |i| create(:activity, started_at: (i + 1).days.ago, average_pace_per_km: 350.0) }
      4.times { |i| create(:activity, started_at: (i + 30).days.ago, average_pace_per_km: 370.0) }

      expect(payload[:comparison_to_previous_period][:pace_change_seconds_per_km]).to eq(-20.0)
      expect(payload[:notable]).to include(a_string_matching(/20\.0s\/km faster/))
    end

    it "reports a positive pace delta when the runner got slower" do
      4.times { |i| create(:activity, started_at: (i + 1).days.ago, average_pace_per_km: 380.0) }
      4.times { |i| create(:activity, started_at: (i + 30).days.ago, average_pace_per_km: 360.0) }

      expect(payload[:comparison_to_previous_period][:pace_change_seconds_per_km]).to eq(20.0)
      expect(payload[:notable]).to include(a_string_matching(/20\.0s\/km slower/))
    end

    it "suppresses the pace delta when either period is too thin to trend" do
      create(:activity, started_at: 1.day.ago, average_pace_per_km: 350.0)
      create(:activity, started_at: 30.days.ago, average_pace_per_km: 400.0)

      expect(payload[:comparison_to_previous_period][:pace_change_seconds_per_km]).to be_nil
    end

    it "reports volume change as a percentage" do
      create(:activity, started_at: 2.days.ago, distance_meters: 20_000)
      create(:activity, started_at: 32.days.ago, distance_meters: 10_000)

      expect(payload[:comparison_to_previous_period][:distance_change_pct]).to eq(100.0)
    end

    it "reports the grade-adjusted delta alongside the raw one" do
      4.times { |i| create(:activity, started_at: (i + 1).days.ago, average_pace_per_km: 350.0, avg_grade_adjusted_pace_per_km: 348.0) }
      4.times { |i| create(:activity, started_at: (i + 30).days.ago, average_pace_per_km: 370.0, avg_grade_adjusted_pace_per_km: 350.0) }

      comparison = payload[:comparison_to_previous_period]
      expect(comparison[:pace_change_seconds_per_km]).to eq(-20.0)
      expect(comparison[:grade_adjusted_pace_change_seconds_per_km]).to eq(-2.0)
    end

    # The whole point of carrying both figures: raw pace improving while the
    # grade-adjusted figure holds flat means the routes got easier.
    it "calls out a raw improvement that the terrain explains" do
      4.times { |i| create(:activity, started_at: (i + 1).days.ago, average_pace_per_km: 350.0, avg_grade_adjusted_pace_per_km: 348.0) }
      4.times { |i| create(:activity, started_at: (i + 30).days.ago, average_pace_per_km: 380.0, avg_grade_adjusted_pace_per_km: 350.0) }

      expect(payload[:notable]).to include(a_string_matching(/trends disagree/))
    end

    it "reports how much the terrain cost when the routes were hilly" do
      3.times { |i| create(:activity, :hilly, started_at: (i + 1).days.ago) }

      expect(payload[:notable]).to include(a_string_matching(/Terrain cost about 30\.0s\/km/))
    end
  end

  describe "notable signals" do
    it "says plainly when there is nothing to report on" do
      expect(payload[:notable]).to include(a_string_matching(/No activities recorded/))
    end

    it "warns when the sample is too thin for the averages to mean anything" do
      create(:activity, started_at: 2.days.ago)

      expect(payload[:notable]).to include(a_string_matching(/averages and comparisons are unreliable/))
    end

    it "surfaces significant aerobic decoupling" do
      4.times { |i| create(:activity, started_at: (i + 1).days.ago, aerobic_decoupling_pct: 14.0) }

      expect(payload[:notable]).to include(a_string_matching(/above the 10% threshold/))
    end

    it "surfaces an elevated acute:chronic ratio" do
      21.times { |i| create(:activity, started_at: (i + 7).days.ago, tss_score: 10.0) }
      7.times { |i| create(:activity, started_at: i.days.ago, tss_score: 120.0) }

      expect(payload[:notable]).to include(a_string_matching(/outside the typical 0\.8-1\.3 range/))
    end
  end

  describe "shaping contract" do
    it "never returns a raw activity list" do
      create_list(:activity, 5)

      expect(payload.keys).to contain_exactly(
        :period, :training_context, :volume, :terrain, :training_load,
        :intensity_distribution, :aerobic_signals,
        :comparison_to_previous_period, :notable
      )
    end

    it "handles an empty database without raising" do
      expect { payload }.not_to raise_error
      expect(payload[:volume][:activity_count]).to eq(0)
      expect(payload[:training_load][:total_tss]).to eq(0.0)
    end

    it "clamps an out-of-range period rather than rejecting it" do
      expect(described_class.call(days: 9_999).structured_content[:period][:days]).to eq(365)
      expect(described_class.call(days: 0).structured_content[:period][:days]).to eq(1)
    end
  end
end
