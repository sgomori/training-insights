require "rails_helper"

RSpec.describe AnalyticalTools::GetPersonalRecords do
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

  def record_for(key)
    payload[:records].find { |record| record[:distance_bucket] == key }
  end

  describe "records at the standard distances" do
    it "picks the fastest qualifying effort at each distance" do
      run_on("2026-05-01", distance_meters: 10_050, duration_seconds: 2_700.0, average_pace_per_km: 268.7)
      run_on("2026-05-20", distance_meters: 9_980, duration_seconds: 2_600.0, average_pace_per_km: 260.5)
      run_on("2026-06-01", distance_meters: 10_000, duration_seconds: 2_800.0, average_pace_per_km: 280.0)

      record = record_for("10k")
      expect(record[:best]).to include(date: "2026-05-20", actual_distance_km: 9.98, pace_per_km: 260.5)
      expect(record[:attempts_considered]).to eq(3)
    end

    it "recognises an effort anywhere inside the tolerance band" do
      run_on("2026-05-01", distance_meters: 4_600, average_pace_per_km: 300.0)
      run_on("2026-05-02", distance_meters: 5_480, average_pace_per_km: 310.0)

      expect(record_for("5k")[:attempts_considered]).to eq(2)
    end

    it "excludes efforts outside the tolerance band" do
      run_on("2026-05-01", distance_meters: 4_400, average_pace_per_km: 250.0)
      run_on("2026-05-02", distance_meters: 5_000, average_pace_per_km: 300.0)

      expect(record_for("5k")[:best]).to include(actual_distance_km: 5.0)
      expect(record_for("5k")[:attempts_considered]).to eq(1)
    end

    # A watch never measures the nominal distance, so ranking on elapsed time
    # would hand the record to whichever effort was shortest.
    it "ranks on pace rather than elapsed time" do
      run_on("2026-05-01", distance_meters: 4_600, duration_seconds: 1_380.0, average_pace_per_km: 300.0)
      run_on("2026-05-02", distance_meters: 5_400, duration_seconds: 1_566.0, average_pace_per_km: 290.0)

      best = record_for("5k")[:best]
      expect(best[:actual_distance_km]).to eq(5.4)
      expect(best[:duration_seconds]).to eq(1_566)
    end

    it "restates the pace as an equivalent time over the nominal distance" do
      run_on("2026-05-02", distance_meters: 5_400, duration_seconds: 1_566.0, average_pace_per_km: 290.0)

      expect(record_for("5k")[:best][:equivalent_time_at_nominal_distance]).to eq(1_450)
    end

    it "omits a distance with no qualifying effort rather than reporting a null best" do
      run_on("2026-05-01", distance_meters: 10_000, average_pace_per_km: 280.0)

      expect(payload[:records].map { |r| r[:distance_bucket] }).to eq([ "10k" ])
      expect(payload[:caveats]).to include(a_string_matching(/No effort within tolerance of 5k, half, and marathon/))
    end

    it "filters to the requested distances" do
      run_on("2026-05-01", distance_meters: 5_000, average_pace_per_km: 300.0)
      run_on("2026-05-02", distance_meters: 10_000, average_pace_per_km: 290.0)

      result = described_class.call(distances: [ "10k" ]).structured_content
      expect(result[:records].map { |r| r[:distance_bucket] }).to eq([ "10k" ])
    end

    it "returns a failure on an unknown distance rather than silently ignoring it" do
      response = described_class.call(distances: [ "10k", "ultra" ])

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to match(/Unknown distance: ultra/)
    end
  end

  describe "race-linked efforts" do
    let!(:race) do
      create(:race, name: "Spring 10K", race_date: Date.new(2026, 5, 10), distance_meters: 10_000,
        result_time_seconds: 2_600, status: "completed")
    end

    it "names the race the record was set at" do
      run_on("2026-05-10", race: race, distance_meters: 10_030, average_pace_per_km: 259.2)

      expect(record_for("10k")[:best]).to include(race_name: "Spring 10K", race_result_time_seconds: 2_600)
    end

    # A race result is the more meaningful number, so it takes a tie.
    it "prefers the race when two efforts are equally fast" do
      run_on("2026-04-01", distance_meters: 10_000, average_pace_per_km: 270.0)
      run_on("2026-05-10", race: race, distance_meters: 10_000, average_pace_per_km: 270.0)

      expect(record_for("10k")[:best][:race_name]).to eq("Spring 10K")
    end

    it "still lets a faster training run hold the record" do
      run_on("2026-04-01", distance_meters: 10_000, average_pace_per_km: 250.0)
      run_on("2026-05-10", race: race, distance_meters: 10_000, average_pace_per_km: 270.0)

      expect(record_for("10k")[:best]).not_to have_key(:race_name)
    end

    it "omits the race fields entirely on a training-run record" do
      run_on("2026-04-01", distance_meters: 10_000, average_pace_per_km: 250.0)

      expect(record_for("10k")[:best].keys).not_to include(:race_name, :race_result_time_seconds)
    end
  end

  describe "notable efforts" do
    it "reports the longest run" do
      run_on("2026-05-01", distance_meters: 32_500, duration_seconds: 11_000.0)
      run_on("2026-05-02", distance_meters: 10_000)

      expect(payload[:notable_efforts][:longest_run]).to include(
        date: "2026-05-01", distance_km: 32.5, duration_seconds: 11_000
      )
    end

    it "reports the biggest week by distance" do
      # Week of 2026-05-04 carries 45km; week of 2026-05-11 carries 30km.
      run_on("2026-05-04", distance_meters: 20_000)
      run_on("2026-05-06", distance_meters: 25_000)
      run_on("2026-05-11", distance_meters: 30_000)

      expect(payload[:notable_efforts][:biggest_week]).to include(
        starting: "2026-05-04", distance_km: 45.0, activity_count: 2
      )
    end

    it "reports the biggest month by distance" do
      run_on("2026-04-10", distance_meters: 30_000)
      run_on("2026-05-10", distance_meters: 20_000)
      run_on("2026-05-20", distance_meters: 25_000)

      expect(payload[:notable_efforts][:biggest_month]).to include(starting: "2026-05-01", distance_km: 45.0)
    end

    # Week and month boundaries land in the runner's timezone, so a late-evening
    # run counts on the day it was run.
    it "buckets a late run into the local day's week" do
      create(:activity, started_at: zone.parse("2026-05-10 23:30"), distance_meters: 20_000)

      # 2026-05-10 is a Sunday, so the local week began on the 4th. In UTC the
      # run lands on Monday the 11th and would open a new week.
      expect(payload[:notable_efforts][:biggest_week][:starting]).to eq("2026-05-04")
    end

    it "reports the highest single-activity load" do
      run_on("2026-05-01", tss_score: 90.0)
      run_on("2026-05-02", tss_score: 240.0, distance_meters: 42_500)

      expect(payload[:notable_efforts][:highest_load_activity]).to include(
        date: "2026-05-02", tss_score: 240.0, distance_km: 42.5
      )
    end

    it "takes the best efficiency factor over training efforts only" do
      race = create(:race, race_date: Date.new(2026, 5, 10), distance_meters: 10_000, status: "completed")
      run_on("2026-05-10", race: race, grade_adjusted_efficiency_factor: 1.95)
      run_on("2026-05-12", grade_adjusted_efficiency_factor: 1.45)

      best = payload[:notable_efforts][:best_efficiency_factor]
      expect(best).to include(date: "2026-05-12", grade_adjusted_efficiency_factor: 1.45)
      expect(best[:basis]).to match(/Races are excluded/)
    end

    it "omits an effort that no activity supplies rather than reporting a null" do
      run_on("2026-05-01", :without_computed_metrics)

      expect(payload[:notable_efforts]).not_to have_key(:highest_load_activity)
      expect(payload[:notable_efforts]).not_to have_key(:best_efficiency_factor)
      expect(payload[:notable_efforts]).to have_key(:longest_run)
    end
  end

  describe "stating the basis" do
    # The limitation has to be visible: a client must know it is seeing best
    # complete efforts, not best segments.
    it "says these are complete efforts rather than segments" do
      expect(payload[:basis]).to match(/not segment records/)
      expect(payload[:basis]).to match(/fastest 5km inside a longer run is not considered/)
    end

    it "reports the span of history the records are drawn from" do
      run_on("2026-01-01", distance_meters: 10_000, average_pace_per_km: 280.0)
      run_on("2026-06-01", distance_meters: 10_000, average_pace_per_km: 290.0)

      expect(payload[:history]).to include(activities: 2, first_activity_date: "2026-01-01", spans_days: 166)
    end

    it "flags a record standing on a single effort" do
      run_on("2026-05-01", distance_meters: 10_000, average_pace_per_km: 280.0)

      expect(payload[:caveats]).to include(a_string_matching(/only one qualifying effort/))
    end

    it "counts qualifying efforts that could not be ranked for want of a pace" do
      run_on("2026-05-01", distance_meters: 10_000, average_pace_per_km: 280.0)
      run_on("2026-05-02", distance_meters: 10_000, average_pace_per_km: nil)

      expect(record_for("10k")[:attempts_without_pace]).to eq(1)
      expect(payload[:caveats]).to include(a_string_matching(/carry no average pace and could not be ranked/))
    end
  end

  describe "shaping contract" do
    it "returns records and career bests with the basis attached" do
      run_on("2026-05-01", distance_meters: 10_000, average_pace_per_km: 280.0)

      expect(payload.keys).to contain_exactly(:basis, :history, :records, :notable_efforts, :caveats)
    end

    it "handles an empty database without raising" do
      expect { payload }.not_to raise_error
      expect(payload[:records]).to eq([])
      expect(payload[:notable_efforts]).to eq({})
      expect(payload[:history]).to include(activities: 0)
    end
  end
end
