require "rails_helper"

RSpec.describe AnalyticalTools::GetTrainingBlockSummary do
  subject(:payload) { described_class.call(**args).structured_content }

  let(:args) { { start_date: "2026-05-04", end_date: "2026-06-14" } }
  let!(:runner) { create(:runner, timezone: "America/Toronto") }
  let(:zone) { ActiveSupport::TimeZone["America/Toronto"] }

  around do |example|
    travel_to(Time.utc(2026, 6, 15, 12, 0, 0)) { example.run }
  end

  def run_on(date, *traits, **attrs)
    create(:activity, *traits, started_at: zone.parse(date.to_s).change(hour: 9), **attrs)
  end

  describe "resolving the block" do
    it "takes explicit dates" do
      expect(payload[:block]).to include(from: "2026-05-04", to: "2026-06-14", days: 42, weeks: 6.0)
    end

    it "accepts days as a convenience, ending today" do
      block = described_class.call(days: 14).structured_content[:block]

      expect(block).to include(from: "2026-06-02", to: "2026-06-15", days: 14)
    end

    it "defaults to eight weeks ending today" do
      block = described_class.call.structured_content[:block]

      expect(block).to include(days: 56, to: "2026-06-15")
    end

    it "runs a block from a start date up to today when no end is given" do
      block = described_class.call(start_date: "2026-06-01").structured_content[:block]

      expect(block).to include(from: "2026-06-01", to: "2026-06-15")
    end

    it "returns a failure when the dates are the wrong way round" do
      response = described_class.call(start_date: "2026-06-14", end_date: "2026-05-04")

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to match(/cannot end before it begins/)
    end

    it "returns a failure on an unreadable date" do
      expect(described_class.call(start_date: "start of May").error?).to be(true)
    end

    it "shortens a block longer than a year and says it did" do
      result = described_class.call(start_date: "2020-01-01", end_date: "2026-06-14").structured_content

      expect(result[:block][:days]).to eq(365)
      expect(result[:block][:note]).to match(/shortened to 365/)
      expect(result[:notable]).to include(a_string_matching(/was shortened to the last 365/))
    end

    it "carries the runner's current load state" do
      expect(payload[:training_context]).to include(:acute_chronic_ratio)
    end
  end

  describe "key workout detection" do
    it "qualifies the longest run of each week" do
      run_on("2026-06-09", distance_meters: 10_000)
      run_on("2026-06-11", distance_meters: 25_000)
      run_on("2026-06-12", distance_meters: 12_000)

      longest = payload[:key_workouts].find { |w| w[:date] == "2026-06-11" }
      expect(longest[:qualified_as]).to include("longest_run_of_week")
      expect(payload[:key_workouts].map { |w| w[:date] }).not_to include("2026-06-12")
    end

    it "qualifies the top quartile of the block by load" do
      run_on("2026-06-01", distance_meters: 5_000, tss_score: 30.0)
      run_on("2026-06-02", distance_meters: 5_000, tss_score: 40.0)
      run_on("2026-06-03", distance_meters: 5_000, tss_score: 50.0)
      run_on("2026-06-04", distance_meters: 5_000, tss_score: 140.0)

      hardest = payload[:key_workouts].find { |w| w[:date] == "2026-06-04" }
      expect(hardest[:qualified_as]).to include("top_quartile_load")
    end

    # A quartile over three activities is not a quartile.
    it "sits the load rule out on a block too small to have quartiles" do
      run_on("2026-06-01", distance_meters: 5_000, tss_score: 30.0)
      run_on("2026-06-02", distance_meters: 5_000, tss_score: 140.0)

      reasons = payload[:key_workouts].flat_map { |w| w[:qualified_as] }
      expect(reasons).not_to include("top_quartile_load")
      expect(payload[:notable]).to include(a_string_matching(/top-quartile load rule was not applied/))
    end

    it "qualifies a session spending more than a fifth of its time above zone 4" do
      run_on("2026-06-10", distance_meters: 5_000,
        hr_zone_distribution: { "zone_2" => 60.0, "zone_4" => 25.0, "zone_5" => 15.0 })

      workout = payload[:key_workouts].find { |w| w[:date] == "2026-06-10" }
      expect(workout[:qualified_as]).to include("time_above_zone_4")
      expect(workout[:time_above_zone_4_pct]).to eq(40.0)
    end

    it "does not qualify a session just below the zone threshold" do
      run_on("2026-06-10", distance_meters: 5_000,
        hr_zone_distribution: { "zone_2" => 80.0, "zone_4" => 20.0 })

      reasons = payload[:key_workouts].flat_map { |w| w[:qualified_as] }
      expect(reasons).not_to include("time_above_zone_4")
    end

    it "qualifies a structured session on its pace variability" do
      run_on("2026-06-10", :interval_session, distance_meters: 5_000)

      workout = payload[:key_workouts].find { |w| w[:date] == "2026-06-10" }
      expect(workout[:qualified_as]).to include("structured_pacing")
    end

    it "qualifies a race effort" do
      race = create(:race, name: "Spring Half", race_date: Date.new(2026, 6, 7),
        distance_meters: 21_097, status: "completed")
      run_on("2026-06-07", race: race, distance_meters: 21_100)

      workout = payload[:key_workouts].find { |w| w[:date] == "2026-06-07" }
      expect(workout[:qualified_as]).to include("race_effort")
    end

    it "names every rule that fired, not just the first" do
      race = create(:race, race_date: Date.new(2026, 6, 7), distance_meters: 21_097, status: "completed")
      run_on("2026-06-07", :interval_session, race: race, distance_meters: 30_000, tss_score: 200.0,
        hr_zone_distribution: { "zone_4" => 50.0, "zone_5" => 20.0 })
      3.times { |i| run_on(Date.new(2026, 6, 1) + i, distance_meters: 5_000, tss_score: 30.0) }

      workout = payload[:key_workouts].find { |w| w[:date] == "2026-06-07" }
      expect(workout[:qualified_as]).to contain_exactly(
        "longest_run_of_week", "top_quartile_load", "time_above_zone_4", "structured_pacing", "race_effort"
      )
    end

    it "leaves the zone rule unapplied rather than assuming an easy run when zones are missing" do
      run_on("2026-06-10", :without_computed_metrics, distance_meters: 5_000)

      workout = payload[:key_workouts].find { |w| w[:date] == "2026-06-10" }
      expect(workout[:time_above_zone_4_pct]).to be_nil
      expect(payload[:notable]).to include(a_string_matching(/no heart rate zone distribution/))
    end

    it "says plainly when nothing qualified" do
      # A single easy run is not the longest of its week only because it is the
      # only one — so give it company at the same distance.
      run_on("2026-06-10", distance_meters: 10_000, tss_score: 50.0, pace_cv: 0.09,
        hr_zone_distribution: { "zone_2" => 100.0 })
      Activity.update_all(distance_meters: nil)

      expect(payload[:notable]).to include(a_string_matching(/No activity in the block qualified/))
      expect(payload[:key_workouts]).to eq([])
    end
  end

  describe "peak week and longest run" do
    it "reports the peak week by distance over complete weeks" do
      run_on("2026-06-01", distance_meters: 10_000)
      run_on("2026-06-08", distance_meters: 30_000)
      run_on("2026-06-09", distance_meters: 20_000)

      peak = payload[:peak_week]
      expect(peak[:week][:week_start]).to eq("2026-06-08")
      expect(peak[:week][:distance_km]).to eq(50.0)
      expect(peak[:basis]).to match(/complete weeks/)
    end

    it "falls back to partial weeks when the block contains none complete, and says so" do
      result = described_class.call(start_date: "2026-06-09", end_date: "2026-06-11").structured_content

      expect(result[:peak_week][:basis]).to match(/No week of the block falls entirely inside it/)
    end

    it "reports the longest run with its own figures" do
      run_on("2026-06-01", distance_meters: 10_000)
      run_on("2026-06-08", distance_meters: 32_000, duration_seconds: 10_800.0, elevation_gain_meters: 210.4)

      expect(payload[:longest_run]).to include(
        date: "2026-06-08", distance_km: 32.0, duration_seconds: 10_800, elevation_gain_meters: 210
      )
    end

    it "returns no longest run rather than a null-filled one on an empty block" do
      expect(payload[:longest_run]).to be_nil
    end
  end

  describe "races in the block" do
    let!(:race) do
      create(:race, name: "Spring Half", race_date: Date.new(2026, 6, 7), distance_meters: 21_097,
        target_time_seconds: 5_400, result_time_seconds: 5_512, status: "completed")
    end

    before do
      run_on("2026-06-07", race: race, distance_meters: 21_140.0, duration_seconds: 5_512.0)
      3.times { |i| run_on(Date.new(2026, 6, 1) + i, distance_meters: 10_000) }
    end

    it "lists the race with its target and result" do
      expect(payload[:races].first).to include(
        date: "2026-06-07", race_name: "Spring Half", distance_km: 21.14,
        target_time_seconds: 5_400, result_time_seconds: 5_512
      )
    end

    # A race is both a race and a key workout. Appearing in both is correct.
    it "also lists the race among the key workouts" do
      expect(payload[:key_workouts].map { |w| w[:date] }).to include("2026-06-07")
    end

    it "counts the race in volume while keeping it out of the aerobic averages" do
      expect(payload[:volume][:activity_count]).to eq(4)
      expect(payload[:aerobic_signals][:basis]).to match(/1 race effort excluded/)
    end
  end

  describe "block shape signals" do
    it "flags a final week well below the peak as a taper or an interruption" do
      # Three complete weeks: 60km, 80km, then 20km.
      3.times { |i| run_on(Date.new(2026, 6, 1) + i, distance_meters: 20_000) }
      4.times { |i| run_on(Date.new(2026, 5, 25) + i, distance_meters: 20_000) }
      run_on("2026-06-09", distance_meters: 20_000)

      result = described_class.call(start_date: "2026-05-25", end_date: "2026-06-14").structured_content
      expect(result[:notable]).to include(a_string_matching(/of its peak week by distance/))
    end

    it "flags a block resting on a single effort" do
      run_on("2026-06-08", distance_meters: 40_000)
      run_on("2026-06-09", distance_meters: 5_000)

      expect(payload[:notable]).to include(a_string_matching(/accounts for 89% of the block's distance/))
    end
  end

  describe "shaping contract" do
    it "returns the block composition plus its own sections" do
      run_on("2026-06-10")

      expect(payload.keys).to contain_exactly(
        :block, :training_context, :volume, :terrain, :load, :intensity_distribution,
        :aerobic_signals, :weekly_breakdown, :peak_week, :longest_run, :key_workouts,
        :races, :notable
      )
    end

    it "handles an empty block without raising" do
      expect { payload }.not_to raise_error
      expect(payload[:key_workouts]).to eq([])
      expect(payload[:races]).to eq([])
      expect(payload[:notable]).to include(a_string_matching(/No activities recorded between/))
    end

    it "says when the block is shorter than a week" do
      result = described_class.call(start_date: "2026-06-10", end_date: "2026-06-12").structured_content

      expect(result[:notable]).to include(a_string_matching(/shorter than a week/))
    end
  end
end
