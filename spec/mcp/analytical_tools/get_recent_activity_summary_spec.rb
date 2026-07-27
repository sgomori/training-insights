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
    it "aggregates distance, duration and elevation" do
      create(:activity, started_at: 2.days.ago, distance_meters: 10_000, duration_seconds: 3_600, elevation_gain_meters: 100)
      create(:activity, started_at: 3.days.ago, distance_meters: 5_000, duration_seconds: 1_800, elevation_gain_meters: 50)

      expect(payload[:volume]).to include(
        activity_count: 2,
        total_distance_km: 15.0,
        total_duration_hours: 1.5,
        total_elevation_gain_m: 150,
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
    it "normalises chronic load to a weekly figure so the ratio sits near 1.0 for steady training" do
      # 60 TSS every day for 28 days: acute (7d) = 420, chronic weekly = 420.
      28.times { |i| create(:activity, started_at: i.days.ago, tss_score: 60.0) }

      load = payload[:training_load]
      expect(load[:total_tss]).to eq(1680.0)
      expect(load[:chronic_weekly_tss]).to eq(420.0)
      expect(load[:acute_chronic_ratio]).to be_within(0.05).of(1.0)
    end

    it "reports a ratio above 1.0 when recent load spikes" do
      21.times { |i| create(:activity, started_at: (i + 7).days.ago, tss_score: 20.0) }
      7.times { |i| create(:activity, started_at: i.days.ago, tss_score: 100.0) }

      expect(payload[:training_load][:acute_chronic_ratio]).to be > 1.5
    end

    it "excludes activities with no TSS and says how many were missing" do
      create(:activity, started_at: 2.days.ago, tss_score: 50.0)
      create(:activity, :without_computed_metrics, started_at: 3.days.ago)

      load = payload[:training_load]
      expect(load[:total_tss]).to eq(50.0)
      expect(load[:activities_missing_tss]).to eq(1)
    end

    it "flags that a short period cannot yield a true chronic load" do
      create(:activity, started_at: 2.days.ago)

      result = described_class.call(days: 10).structured_content
      expect(result[:training_load][:sufficient_history_for_chronic_load]).to be(false)
      expect(result[:notable]).to include(a_string_matching(/shorter than 28 days/))
    end

    it "flags a 28-day window that has less than 28 days of history behind it" do
      create(:activity, started_at: 5.days.ago)

      load = payload[:training_load]
      expect(load[:sufficient_history_for_chronic_load]).to be(false)
      expect(load[:history_spans_days]).to eq(6)
      expect(payload[:notable]).to include(a_string_matching(/Only 6 days of history exist/))
    end

    it "accepts the chronic figure once enough history exists" do
      create(:activity, started_at: 40.days.ago)
      create(:activity, started_at: 2.days.ago)

      expect(payload[:training_load][:sufficient_history_for_chronic_load]).to be(true)
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

    it "states which direction counts as improvement" do
      create(:activity, started_at: 2.days.ago)

      signals = payload[:aerobic_signals]
      expect(signals[:average_pace_per_km][:interpretation]).to match(/lower is faster/)
      expect(signals[:efficiency_factor][:interpretation]).to match(/higher is better/)
      expect(signals[:aerobic_decoupling_pct][:interpretation]).to match(/lower is better/)
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

      expect(payload[:notable]).to include(a_string_matching(/well above the typical/))
    end
  end

  describe "shaping contract" do
    it "never returns a raw activity list" do
      create_list(:activity, 5)

      expect(payload.keys).to contain_exactly(
        :period, :volume, :training_load, :intensity_distribution,
        :aerobic_signals, :comparison_to_previous_period, :notable
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
