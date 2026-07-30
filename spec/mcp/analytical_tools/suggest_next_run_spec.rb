require "rails_helper"

RSpec.describe AnalyticalTools::SuggestNextRun do
  subject(:payload) { described_class.call(**args).structured_content }

  let(:args) { {} }
  let!(:runner) { create(:runner, timezone: "America/Toronto") }
  let(:zone) { ActiveSupport::TimeZone["America/Toronto"] }

  around do |example|
    travel_to(Time.utc(2026, 6, 15, 12, 0, 0)) { example.run }
  end

  def run_on(date, *traits, **attrs)
    create(:activity, *traits, started_at: zone.parse(date.to_s).change(hour: 9), **attrs)
  end

  def reading(type, date, **measurements)
    create(:health_metric, metric_type: type, recorded_date: Date.parse(date), measurements: measurements)
  end

  describe "the non-goal it holds to" do
    # V1_SCOPE.md: not a coaching service. Tools return shaped data and do not
    # prescribe training.
    it "states plainly that it prescribes nothing" do
      expect(payload[:purpose]).to match(/does not prescribe training/)
    end

    it "returns no prescription anywhere in the response" do
      run_on("2026-06-14")

      expect(payload.to_json).not_to match(/\byou should\b|\byou need\b|\btake a rest\b|\bwe suggest\b/i)
    end
  end

  describe "last activity" do
    it "reports the last run with how long ago it was and how hard" do
      run_on("2026-06-13", distance_meters: 18_000, tss_score: 95.0, pace_cv: 0.24)

      last = payload[:last_activity]
      expect(last).to include(date: "2026-06-13", days_ago: 2, distance_km: 18.0, tss_score: 95.0)
      expect(last[:pace_cv][:band]).to eq("highly variable — intervals or trail")
    end

    it "names a race, since the fortnight after one reads differently" do
      race = create(:race, name: "Spring Half", race_date: Date.new(2026, 6, 7),
        distance_meters: 21_097, status: "completed")
      run_on("2026-06-07", race: race)

      expect(payload[:last_activity]).to include(was_a_race: true, race_name: "Spring Half")
      expect(payload[:notable]).to include(a_string_matching(/A race was run 8 days ago/))
    end

    it "says there is no training to read against on an empty database" do
      expect(payload[:last_activity][:note]).to match(/no training to read against/)
      expect(payload[:notable]).to include("No activities have been ingested.")
    end

    it "flags a long gap since the last activity" do
      run_on("2026-06-01")

      expect(payload[:notable]).to include(a_string_matching(/14 days ago, so the acute load figure/))
    end

    it "flags an unbroken training block" do
      8.times { |i| run_on(Date.new(2026, 6, 15) - i) }

      expect(payload[:notable]).to include(a_string_matching(/8 consecutive training days/))
    end
  end

  describe "recovery indicators" do
    # The n8n feed that supplies these is a separate ingestion path, so its
    # absence must not read as a statement about the runner.
    it "says the data is unavailable and names the missing types" do
      run_on("2026-06-14")

      recovery = payload[:recovery_indicators]
      expect(recovery[:available]).to be(false)
      expect(recovery[:missing_metric_types]).to contain_exactly("hrv", "resting_hr", "sleep")
      expect(recovery[:note]).to match(/gap in that feed rather than a statement about the runner/)
      expect(payload[:notable]).to include(a_string_matching(/No recovery data is available/))
    end

    it "compares the latest reading against its trailing baseline" do
      # The 28 days immediately before the latest reading: 2026-05-18 to 06-14.
      28.times { |i| reading("hrv", (Date.new(2026, 6, 14) - i).to_s, "hrv_ms" => 60.0) }
      reading("hrv", "2026-06-15", "hrv_ms" => 48.0)

      hrv = payload[:recovery_indicators][:hrv]
      expect(hrv).to include(
        value: 48.0, baseline: 60.0, baseline_days: 28, baseline_sample_size: 28,
        deviation_from_baseline: -12.0, days_old: 0
      )
    end

    it "expresses the deviation in standard deviations, which is how HRV is read" do
      # Baseline of 55, 60, 65 — a population spread of about 4.08.
      reading("hrv", "2026-06-12", "hrv_ms" => 55.0)
      reading("hrv", "2026-06-13", "hrv_ms" => 60.0)
      reading("hrv", "2026-06-14", "hrv_ms" => 65.0)
      reading("hrv", "2026-06-15", "hrv_ms" => 48.0)

      hrv = payload[:recovery_indicators][:hrv]
      expect(hrv[:baseline]).to eq(60.0)
      expect(hrv[:deviation_in_standard_deviations]).to eq(-2.94)
      expect(payload[:notable]).to include(a_string_matching(/hrv is 2\.94 standard deviations below/))
    end

    it "carries the shared reading guidance and gives HRV no absolute bands" do
      reading("hrv", "2026-06-15", "hrv_ms" => 62.0)

      hrv = payload[:recovery_indicators][:hrv]
      expect(hrv).to include(unit: "milliseconds", direction: "higher_is_better")
      expect(hrv).not_to have_key(:reference_bands)
    end

    it "bands a sleep score, which is already normalised" do
      reading("sleep", "2026-06-15", "sleep_score" => 84)

      expect(payload[:recovery_indicators][:sleep][:band]).to eq("good")
    end

    # A two-week-old HRV number is not a recovery indicator.
    it "reports the age of a stale reading and says what it describes" do
      reading("hrv", "2026-06-01", "hrv_ms" => 62.0)

      hrv = payload[:recovery_indicators][:hrv]
      expect(hrv[:days_old]).to eq(14)
      expect(hrv[:caveats]).to include(a_string_matching(/describes the day it was taken/))
      expect(payload[:notable]).to include(a_string_matching(/hrv reading is 14 days old/))
    end

    it "says a single reading has no baseline to be read against" do
      reading("hrv", "2026-06-15", "hrv_ms" => 62.0)

      hrv = payload[:recovery_indicators][:hrv]
      expect(hrv[:baseline]).to be_nil
      expect(hrv[:caveats]).to include(a_string_matching(/not interpretable from a single value/))
    end

    it "names the types still missing when only some have readings" do
      reading("hrv", "2026-06-15", "hrv_ms" => 62.0)

      recovery = payload[:recovery_indicators]
      expect(recovery[:available]).to be(true)
      expect(recovery[:missing_metric_types]).to contain_exactly("resting_hr", "sleep")
      expect(recovery).not_to have_key(:resting_hr)
    end
  end

  describe "intensity balance" do
    it "reports the duration-weighted easy share against the 80/20 convention" do
      run_on("2026-06-13", duration_seconds: 3_600,
        hr_zone_distribution: { "zone_1" => 20.0, "zone_2" => 60.0, "zone_4" => 20.0 })

      balance = payload[:intensity_balance][:last_7d]
      expect(balance).to include(easy_pct: 80.0, harder_than_easy_pct: 20.0, deviation_from_80_20: 0.0)
    end

    it "weights by duration rather than averaging the percentages" do
      run_on("2026-06-13", duration_seconds: 10_800, hr_zone_distribution: { "zone_2" => 100.0 })
      run_on("2026-06-14", duration_seconds: 3_600, hr_zone_distribution: { "zone_4" => 100.0 })

      expect(payload[:intensity_balance][:last_7d][:easy_pct]).to eq(75.0)
    end

    it "reports both a 7-day and a 28-day view" do
      expect(payload[:intensity_balance].keys).to include(:last_7d, :last_28d)
    end

    it "flags a split well away from the convention" do
      run_on("2026-06-13", duration_seconds: 3_600,
        hr_zone_distribution: { "zone_2" => 50.0, "zone_4" => 50.0 })

      expect(payload[:notable]).to include(a_string_matching(/Only 50\.0% of the last 28 days/))
    end

    it "says the split cannot be computed rather than reporting zero" do
      run_on("2026-06-13", :without_computed_metrics)

      expect(payload[:intensity_balance][:last_7d][:easy_pct]).to be_nil
      expect(payload[:intensity_balance][:last_7d][:note]).to match(/cannot be computed/)
    end
  end

  describe "load headroom" do
    it "solves for the additional load that would reach each threshold" do
      # 28 days at 40 TSS: acute 280, chronic total 1120, chronic weekly 280.
      28.times { |i| run_on(Date.new(2026, 6, 15) - i, tss_score: 40.0) }

      headroom = payload[:load_headroom]
      expect(headroom).to include(current_acute_7d_tss: 280.0, chronic_weekly_tss: 280.0, current_ratio: 1.0)

      # (1.3 * 1120 - 4 * 280) / (4 - 1.3) = 336 / 2.7 = 124.4
      at_1_3 = headroom[:additional_tss_to_reach].find { |h| h[:ratio_threshold] == 1.3 }
      expect(at_1_3[:additional_tss]).to eq(124.4)
    end

    # The added load lands in the chronic window as well as the acute one, so it
    # raises the denominator too. Holding the baseline fixed would understate the
    # headroom — here by 40 TSS out of 124.
    it "accounts for the load also entering the chronic baseline" do
      28.times { |i| run_on(Date.new(2026, 6, 15) - i, tss_score: 40.0) }

      at_1_3 = payload[:load_headroom][:additional_tss_to_reach].find { |h| h[:ratio_threshold] == 1.3 }
      fixed_baseline_answer = (1.3 * 280) - 280

      expect(fixed_baseline_answer).to eq(84.0)
      expect(at_1_3[:additional_tss]).to be > fixed_baseline_answer
      expect(payload[:load_headroom][:basis]).to match(/also entering the chronic baseline/)
    end

    it "verifies the solved figure actually lands on the threshold" do
      28.times { |i| run_on(Date.new(2026, 6, 15) - i, tss_score: 40.0) }

      at_1_5 = payload[:load_headroom][:additional_tss_to_reach].find { |h| h[:ratio_threshold] == 1.5 }
      extra = at_1_5[:additional_tss]
      new_ratio = (280 + extra) / ((1_120 + extra) / 4.0)

      expect(new_ratio).to be_within(0.01).of(1.5)
    end

    it "reports zero rather than a negative headroom once a threshold is passed" do
      21.times { |i| run_on(Date.new(2026, 6, 15) - i - 7, tss_score: 10.0) }
      7.times { |i| run_on(Date.new(2026, 6, 15) - i, tss_score: 130.0) }

      at_1_3 = payload[:load_headroom][:additional_tss_to_reach].find { |h| h[:ratio_threshold] == 1.3 }
      expect(at_1_3[:additional_tss]).to eq(0.0)
      expect(at_1_3[:note]).to match(/already at or above this threshold/)
      expect(payload[:notable]).to include(a_string_matching(/above both thresholds, so the solved headroom is zero/))
    end

    it "says there is no baseline to compute against rather than dividing by zero" do
      expect(payload[:load_headroom][:basis]).to match(/no chronic baseline/)
      expect(payload[:load_headroom]).not_to have_key(:additional_tss_to_reach)
    end

    it "warns when the chronic baseline rests on too little history" do
      run_on("2026-06-14", tss_score: 60.0)

      expect(payload[:notable]).to include(a_string_matching(/not yet a true chronic load/))
    end

    it "notes that missing TSS understates both the ratio and the headroom" do
      run_on("2026-06-13", tss_score: 60.0)
      run_on("2026-06-14", :without_computed_metrics)

      expect(payload[:notable]).to include(a_string_matching(/computed on an understated load/))
    end
  end

  describe "race proximity" do
    it "carries the next race with its goal pace" do
      create(:race, name: "Toronto Waterfront", race_date: Date.new(2026, 7, 13),
        distance_meters: 42_195, target_time_seconds: 12_600, status: "upcoming")

      expect(payload[:race_proximity]).to include(
        name: "Toronto Waterfront", days_until: 28, distance_km: 42.2, target_pace_per_km: 298.6
      )
    end

    it "says when a race has no target time" do
      create(:race, name: "Local 10K", race_date: Date.new(2026, 7, 5),
        distance_meters: 10_000, target_time_seconds: nil, status: "upcoming")

      expect(payload[:race_proximity][:note]).to match(/no goal pace to contextualise against/)
    end

    it "returns null when nothing is scheduled" do
      expect(payload[:race_proximity]).to be_nil
    end
  end

  describe "a planned distance" do
    let(:args) { { planned_distance_km: 24.0 } }

    it "places the plan against recent training without judging it" do
      run_on("2026-06-10", distance_meters: 12_000)
      run_on("2026-06-12", distance_meters: 8_000)

      planned = payload[:planned_run]
      expect(planned).to include(distance_km: 24.0, descriptive_band: "long", vs_average_of_last_28d_pct: 140.0)
      expect(planned[:vs_longest_of_last_28d_pct]).to eq(100.0)
      expect(planned[:basis]).to match(/does not say whether to run it/)
    end

    it "relates the plan to the next race distance" do
      create(:race, race_date: Date.new(2026, 7, 13), distance_meters: 42_195, status: "upcoming")

      expect(payload[:planned_run][:pct_of_next_race_distance]).to eq(56.9)
    end

    it "omits the block entirely when no distance is given" do
      expect(described_class.call.structured_content).not_to have_key(:planned_run)
    end
  end

  describe "shaping contract" do
    it "returns the decision inputs and nothing more" do
      run_on("2026-06-14")

      expect(payload.keys).to contain_exactly(
        :purpose, :training_context, :last_activity, :recovery_indicators,
        :intensity_balance, :load_headroom, :race_proximity, :notable
      )
    end

    it "handles an empty database without raising" do
      expect { payload }.not_to raise_error
      expect(payload[:notable]).to be_present
    end
  end
end
