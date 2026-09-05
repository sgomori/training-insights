require "rails_helper"

RSpec.describe AnalyticalTools::GetRaceProjections do
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

  # A 10k race three months ago, in 44:00, with the linked effort recorded.
  def race_with_effort(date: "2026-03-15", **attrs)
    race = create(:race, name: "Spring 10K", race_date: Date.parse(date), distance_meters: 10_000,
      result_time_seconds: 2_640, status: "completed", **attrs)
    run_on(date, race: race, distance_meters: 10_050, duration_seconds: 2_640.0,
      average_pace_per_km: 262.7, avg_grade_adjusted_pace_per_km: 260.0, elevation_gain_meters: 55.0)
    race
  end

  def race_reference(name)
    payload[:reference_efforts][:races].find { |race| race[:reference][:name] == name }
  end

  def training_reference(bucket)
    payload[:reference_efforts][:training_efforts].find { |ref| ref[:reference][:distance_bucket] == bucket }
  end

  def target(key)
    payload[:by_target].find { |entry| entry[:target] == key }
  end

  def projection(target_key, **reference)
    target(target_key)[:projections].find { |p| reference.all? { |k, v| p[:reference][k] == v } }
  end

  describe "targets" do
    it "defaults to the four standard distances" do
      expect(payload[:targets].map { |t| t[:key] }).to eq(%w[5k 10k half marathon])
      expect(payload[:by_target].map { |t| t[:target] }).to eq(%w[5k 10k half marathon])
    end

    it "restricts to the requested distances" do
      result = described_class.call(distances: [ "5k", "half" ]).structured_content

      expect(result[:targets].map { |t| t[:key] }).to eq(%w[5k half])
    end

    it "adds a custom distance alongside the standard ones" do
      result = described_class.call(distances: [ "10k" ], distance_km: 15).structured_content

      expect(result[:targets]).to include(key: "custom", label: "15.0km", distance_km: 15.0)
    end

    it "returns a failure on an unknown distance rather than silently ignoring it" do
      response = described_class.call(distances: [ "5k", "mile" ])

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to match(/mile/)
    end
  end

  describe "race references" do
    it "describes the race on its nominal distance and keeps the measured figures apart" do
      race_with_effort

      expect(race_reference("Spring 10K")).to include(
        reference: { kind: "race", name: "Spring 10K", date: "2026-03-15", days_ago: 92 },
        distance_km: 10.0, time_seconds: 2_640, pace_per_km_at_nominal_distance: 264.0,
        measured_distance_km: 10.05, measured_pace_per_km: 262.7, grade_adjusted_pace_per_km: 260.0,
        elevation_gain_meters: 55
      )
    end

    it "projects a race to every target with Riegel's model, banded on the ratio" do
      race_with_effort

      # 2640 * (21.1 / 10) ** 1.06
      expect(projection("half", name: "Spring 10K")).to include(
        maximal_effort: true, projected_time_seconds: 5_826, projected_pace_per_km: 276.1,
        distance_ratio: 2.11, direction: "to a longer distance", reliability: "close"
      )
      expect(projection("10k", name: "Spring 10K")).to include(projected_time_seconds: 2_640, distance_ratio: 1.0,
        direction: "same distance", reliability: "close")
      expect(projection("marathon", name: "Spring 10K")).to include(distance_ratio: 4.22, reliability: "wide")
    end

    it "bands both directions of the same pair alike" do
      create(:race, name: "Last Marathon", race_date: Date.new(2025, 10, 12), distance_meters: 42_195,
        result_time_seconds: 14_400, status: "completed")
      race_with_effort

      expect(projection("5k", name: "Last Marathon")).to include(distance_ratio: 0.12, reliability: "far extrapolation")
      expect(projection("half", name: "Last Marathon")).to include(distance_ratio: 0.5, reliability: "close")
      expect(projection("marathon", name: "Spring 10K")).to include(distance_ratio: 4.22, reliability: "wide")
      expect(projection("5k", name: "Spring 10K")).to include(distance_ratio: 0.5, reliability: "close")
    end

    it "bands the unrounded ratio" do
      create(:race, name: "Long Half", race_date: Date.new(2026, 4, 1), distance_meters: 21_097,
        result_time_seconds: 5_900, status: "completed")

      # 63.29 / 21.097 = 2.99996, which displays as 3.0 but sits inside the band
      # the rounded figure would fall out of.
      result = described_class.call(distances: [], distance_km: 63.29).structured_content
      custom = result[:by_target].find { |t| t[:target] == "custom" }[:projections].first
      expect(custom).to include(distance_ratio: 3.0, reliability: "close")
    end

    it "falls back to the linked effort's duration when the calendar has no time" do
      race = create(:race, name: "Untimed 10K", race_date: Date.new(2026, 4, 1), distance_meters: 10_000,
        result_time_seconds: nil, status: "completed")
      run_on("2026-04-01", race: race, distance_meters: 10_020, duration_seconds: 2_700.4, average_pace_per_km: 269.5)

      expect(race_reference("Untimed 10K")).to include(time_seconds: 2_700)
    end

    it "names a race with no time at all rather than dropping it silently" do
      create(:race, name: "Lost Result", race_date: Date.new(2026, 4, 1), distance_meters: 10_000,
        result_time_seconds: nil, status: "completed")

      expect(payload[:reference_efforts][:races]).to eq([])
      expect(payload[:notable]).to include(a_string_matching(/Lost Result has no recorded time/))
    end

    it "ignores races older than the lookback and races still upcoming" do
      create(:race, name: "Old", race_date: Date.new(2025, 6, 1), distance_meters: 10_000,
        result_time_seconds: 2_600, status: "completed")
      create(:race, name: "Next", race_date: Date.new(2026, 8, 1), distance_meters: 10_000,
        target_time_seconds: 2_600, status: "upcoming")
      run_on("2026-06-01", distance_meters: 5_000, average_pace_per_km: 300.0)

      expect(payload[:reference_efforts][:races]).to eq([])
      expect(payload[:windows][:races]).to include(days: 365, from: "2025-06-16", to: "2026-06-15")
      expect(payload[:notable]).to include(a_string_matching(/No timed race in the last 365 days/))
    end
  end

  describe "fitness change since a race" do
    it "compares the month before the race with the current month" do
      race_with_effort
      %w[2026-02-20 2026-02-27 2026-03-06].each do |date|
        run_on(date, grade_adjusted_efficiency_factor: 1.30, aerobic_decoupling_pct: 6.0)
      end
      %w[2026-05-25 2026-06-01 2026-06-08].each do |date|
        run_on(date, grade_adjusted_efficiency_factor: 1.365, aerobic_decoupling_pct: 4.0)
      end

      change = race_reference("Spring 10K")[:fitness_change_since]
      expect(change[:before_race][:grade_adjusted_efficiency_factor]).to eq(value: 1.3, sample_size: 3)
      expect(payload[:current_fitness][:grade_adjusted_efficiency_factor]).to eq(value: 1.365, sample_size: 3)
      expect(change).to include(
        grade_adjusted_efficiency_factor_change_pct: 5.0,
        aerobic_decoupling_change_pct_points: -2.0,
        overlap_days: 0
      )
      expect(change).not_to have_key(:suppressed)
      expect(payload[:notable]).to include(
        a_string_matching(/5\.0% higher than in the 28 days before the Spring 10K \(3 training efforts then\).*Decoupling moved -2\.0 points/)
      )
      expect(payload[:notable]).not_to include(a_string_matching(/conservatively|generously/))
    end

    it "suppresses a change when either side is thin, naming the side, and leaves the key null" do
      race_with_effort
      %w[2026-05-25 2026-06-01 2026-06-08].each { |date| run_on(date) }

      change = race_reference("Spring 10K")[:fitness_change_since]
      expect(change).to include(grade_adjusted_efficiency_factor_change_pct: nil)
      expect(change[:suppressed][:grade_adjusted_efficiency_factor]).to match(/month before the race \(0\)/)
      expect(payload[:notable]).not_to include(a_string_matching(/Efficiency factor rises/))
    end

    it "does not raise a signal for a change below the materiality threshold" do
      race_with_effort
      %w[2026-02-20 2026-02-27 2026-03-06].each { |date| run_on(date, grade_adjusted_efficiency_factor: 1.30) }
      %w[2026-05-25 2026-06-01 2026-06-08].each { |date| run_on(date, grade_adjusted_efficiency_factor: 1.31) }

      expect(race_reference("Spring 10K")[:fitness_change_since]).to include(grade_adjusted_efficiency_factor_change_pct: 0.8)
      expect(payload[:notable]).not_to include(a_string_matching(/Efficiency factor rises/))
    end

    it "reports the overlap for a recent race and keeps the race out of the current volume" do
      race_with_effort(date: "2026-06-10")
      run_on("2026-06-01", distance_meters: 10_000)

      change = race_reference("Spring 10K")[:fitness_change_since]
      expect(change[:overlap_days]).to eq(22)
      expect(change[:basis]).to match(/share 22 days/)
      # Before: one 10km run in 28 days. Current: the same run, with the race itself left out.
      expect(change[:weekly_km_change_pct]).to eq(0.0)
      expect(payload[:current_fitness][:weekly_km]).to eq(5.0)
    end
  end

  describe "training references" do
    it "takes the best complete effort at each standard distance, ranked on grade-adjusted pace" do
      run_on("2026-05-01", distance_meters: 10_050, duration_seconds: 2_700.0, average_pace_per_km: 268.7,
        avg_grade_adjusted_pace_per_km: 255.0)
      run_on("2026-05-20", distance_meters: 9_980, duration_seconds: 2_600.0, moving_time_seconds: 2_580.0,
        average_pace_per_km: 258.5, avg_grade_adjusted_pace_per_km: 257.0,
        hr_zone_distribution: { "zone_1" => 5.0, "zone_2" => 20.0, "zone_3" => 30.0, "zone_4" => 35.0, "zone_5" => 10.0 })

      ref = training_reference("10k")
      expect(ref).to include(
        reference: { kind: "training_effort", distance_bucket: "10k", date: "2026-05-01", days_ago: 45 },
        distance_km: 10.05, time_seconds: 2_700, time_basis: "elapsed", ranked_on: "grade_adjusted_pace",
        attempts_considered: 2, attempts_without_pace: 0
      )
    end

    it "projects from elapsed time so a run with stops in it does not project faster than raced" do
      run_on("2026-05-20", distance_meters: 9_980, duration_seconds: 2_600.0, moving_time_seconds: 2_500.0,
        average_pace_per_km: 250.5)

      ref = training_reference("10k")
      expect(ref).to include(time_seconds: 2_600, moving_time_seconds: 2_500)
      expect(projection("5k", distance_bucket: "10k")).to include(
        maximal_effort: false, projected_time_seconds: (2_600 * (5.0 / 9.98)**1.06).round, reliability: "close"
      )
    end

    it "reconstructs a time from pace only when no duration was recorded" do
      run_on("2026-05-20", distance_meters: 5_000, duration_seconds: nil, average_pace_per_km: 300.0)

      expect(training_reference("5k")).to include(time_seconds: 1_500, time_basis: "moving, reconstructed from pace")
    end

    it "counts qualifying efforts that carry no pace without ranking them" do
      run_on("2026-05-20", distance_meters: 5_000, average_pace_per_km: 300.0)
      run_on("2026-05-21", distance_meters: 5_000, average_pace_per_km: nil)

      expect(training_reference("5k")).to include(attempts_considered: 1, attempts_without_pace: 1)
    end

    it "excludes races, efforts outside the window and efforts outside every tolerance band" do
      race_with_effort
      run_on("2026-02-01", distance_meters: 10_000, average_pace_per_km: 250.0)
      run_on("2026-06-01", distance_meters: 7_500, average_pace_per_km: 250.0)

      expect(payload[:reference_efforts][:training_efforts]).to eq([])
      expect(payload[:notable]).to include(a_string_matching(/No training effort within tolerance.*last 90 days/))
    end

    it "widens the window on request" do
      run_on("2026-02-01", distance_meters: 10_000, average_pace_per_km: 250.0)

      result = described_class.call(days: 180).structured_content
      expect(result[:windows][:training_efforts]).to include(days: 180)
      expect(result[:reference_efforts][:training_efforts].size).to eq(1)
    end

    it "does not claim an effort was easy when it carries no zone distribution" do
      run_on("2026-06-01", :without_computed_metrics, distance_meters: 5_000, average_pace_per_km: 270.0)

      ref = training_reference("5k")
      expect(ref).to include(hard_effort: nil, time_above_zone_4_pct: nil, ranked_on: "pace")
      expect(payload[:notable]).to include(a_string_matching(/1 training reference carries no heart rate zone distribution/))
    end

    it "says when no training reference was a hard session" do
      run_on("2026-06-01", distance_meters: 5_000, average_pace_per_km: 300.0)

      expect(payload[:notable]).to include(a_string_matching(/none was a hard session/))
    end
  end

  describe "the projections by target" do
    it "orders every reference's projection fastest first with the spread between them" do
      race_with_effort
      run_on("2026-06-01", distance_meters: 5_000, duration_seconds: 1_500.0, average_pace_per_km: 300.0)

      entry = target("10k")
      expect(entry).to include(label: "10 kilometres", distance_km: 10.0, reference_count: 2)
      expect(entry[:projections].map { |p| p[:reference][:kind] }).to eq(%w[race training_effort])
      expect(entry[:spread_seconds]).to eq(entry[:projections].last[:projected_time_seconds] - 2_640)
    end

    it "leaves the spread null with a single reference" do
      race_with_effort

      expect(target("10k")).to include(reference_count: 1, spread_seconds: nil)
    end

    it "flags a submaximal effort projecting faster than a race" do
      race_with_effort
      run_on("2026-06-01", distance_meters: 5_000, duration_seconds: 1_200.0, average_pace_per_km: 240.0)

      expect(payload[:notable]).to include(
        a_string_matching(/At the 10 kilometres, the 5k training effort of 2026-06-01 projects \d+ seconds faster than the Spring 10K \(2026-03-15\)/)
      )
    end

    it "says when no reference sits close to a target, and stays quiet when one does" do
      create(:race, name: "Last Marathon", race_date: Date.new(2025, 10, 12), distance_meters: 42_195,
        result_time_seconds: 14_400, status: "completed")

      expect(payload[:notable]).to include(
        a_string_matching(/No reference within a close ratio of the 5 kilometres: the nearest is the Last Marathon \(2025-10-12\).*far extrapolation/)
      )
      expect(payload[:notable]).not_to include(a_string_matching(/close ratio of the half marathon/))
    end
  end

  describe "shaping contract" do
    it "returns the basis, the windows, the band vocabulary, the load state and the current fitness" do
      expect(payload.keys).to contain_exactly(
        :basis, :targets, :windows, :reliability, :training_context, :current_fitness,
        :reference_efforts, :by_target, :notable
      )
      expect(payload[:reliability]).to include(:guidance, :reference_bands)
      expect(payload[:reliability]).not_to have_key(:value)
      expect(payload[:training_context]).to include(:as_of, :acute_chronic_ratio)
      expect(payload[:current_fitness]).to include(:period, :weekly_km, :grade_adjusted_efficiency_factor)
    end

    it "handles an empty database without raising" do
      expect { payload }.not_to raise_error
      expect(payload[:reference_efforts]).to eq(races: [], training_efforts: [])
      expect(payload[:by_target].map { |t| t[:projections] }).to all(eq([]))
      expect(payload[:notable]).to include(a_string_matching(/Nothing can be projected/))
    end
  end
end
