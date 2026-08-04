require "rails_helper"

RSpec.describe AnalyticalTools::GetActivities do
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

  describe "filters" do
    it "returns everything by default, newest first" do
      run_on("2026-06-01")
      run_on("2026-06-10")
      run_on("2026-05-20")

      expect(payload[:activities].map { |a| a[:date] }).to eq([ "2026-06-10", "2026-06-01", "2026-05-20" ])
    end

    it "bounds a date range by calendar days in the runner's timezone" do
      run_on("2026-06-09", distance_meters: 1_000)
      create(:activity, started_at: zone.parse("2026-06-10 23:30"), distance_meters: 2_000)
      run_on("2026-06-16", distance_meters: 3_000)

      result = described_class.call(from: "2026-06-10", to: "2026-06-15").structured_content
      expect(result[:activities].map { |a| a[:distance_km] }).to eq([ 2.0 ])
    end

    it "filters by activity type" do
      run_on("2026-06-10", activity_type: "running")
      run_on("2026-06-11", activity_type: "cycling")

      result = described_class.call(activity_type: "cycling").structured_content
      expect(result[:activities].map { |a| a[:activity_type] }).to eq([ "cycling" ])
    end

    it "filters by distance range" do
      run_on("2026-06-10", distance_meters: 5_000)
      run_on("2026-06-11", distance_meters: 15_000)
      run_on("2026-06-12", distance_meters: 30_000)

      result = described_class.call(min_distance_km: 10, max_distance_km: 20).structured_content
      expect(result[:activities].map { |a| a[:distance_km] }).to eq([ 15.0 ])
    end

    it "filters to race efforts only" do
      race = create(:race, name: "Spring Half", race_date: Date.new(2026, 6, 7),
        distance_meters: 21_097, status: "completed")
      run_on("2026-06-07", race: race)
      run_on("2026-06-10")

      result = described_class.call(races_only: true).structured_content
      expect(result[:total_matching]).to eq(1)
      expect(result[:activities].first.dig(:race, :name)).to eq("Spring Half")
    end

    it "echoes the filters back so the response stands alone" do
      result = described_class.call(from: "2026-06-01", activity_type: "running", min_distance_km: 5).structured_content

      expect(result[:filters_applied]).to include(
        from: "2026-06-01", to: "today (2026-06-15)", timezone: "America/Toronto",
        activity_type: "running", min_distance_km: 5, races_only: false,
        limit: 50, order: "newest_first"
      )
    end

    it "names the unbounded ends rather than omitting them" do
      expect(payload[:filters_applied][:from]).to eq("start of history")
    end

    it "returns a failure rather than an empty list when the distance range is inverted" do
      response = described_class.call(min_distance_km: 20, max_distance_km: 10)

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to match(/greater than max_distance_km/)
    end

    it "returns a failure on an unreadable date" do
      expect(described_class.call(from: "June 1st").error?).to be(true)
    end

    it "says that a distance filter also excludes activities with no distance" do
      run_on("2026-06-10", distance_meters: nil)
      run_on("2026-06-11", distance_meters: 15_000)

      result = described_class.call(min_distance_km: 1).structured_content
      expect(result[:total_matching]).to eq(1)
      expect(result[:notable]).to include(a_string_matching(/no recorded distance are excluded/))
    end
  end

  describe "ordering" do
    before do
      run_on("2026-06-10", distance_meters: 10_000, average_pace_per_km: 300.0)
      run_on("2026-06-11", distance_meters: 30_000, average_pace_per_km: 400.0)
      run_on("2026-06-12", distance_meters: 20_000, average_pace_per_km: nil)
    end

    it "sorts oldest first on request" do
      result = described_class.call(order: "oldest_first").structured_content
      expect(result[:activities].first[:date]).to eq("2026-06-10")
    end

    it "sorts longest first" do
      result = described_class.call(order: "longest_first").structured_content
      expect(result[:activities].map { |a| a[:distance_km] }).to eq([ 30.0, 20.0, 10.0 ])
    end

    # Lower pace is faster, and an activity with no pace is not the fastest one.
    it "sorts fastest first with unpaced activities last" do
      result = described_class.call(order: "fastest_first").structured_content
      expect(result[:activities].map { |a| a[:average_pace_per_km] }).to eq([ 300.0, 400.0, nil ])
    end

    it "falls back to the default rather than failing on an unknown order" do
      result = described_class.call(order: "by_vibes").structured_content
      expect(result[:filters_applied][:order]).to eq("newest_first")
    end
  end

  describe "truncation" do
    before { 60.times { |i| run_on(Date.new(2026, 6, 15) - i) } }

    it "applies a default limit and says it did" do
      expect(payload[:returned]).to eq(50)
      expect(payload[:total_matching]).to eq(60)
      expect(payload[:truncated]).to be(true)
    end

    it "reports the full matching count so a partial view is never mistaken for the whole one" do
      expect(payload[:notable]).to include(a_string_matching(/60 activities match but only 50 were returned/))
    end

    it "honours a requested limit" do
      expect(described_class.call(limit: 5).structured_content[:returned]).to eq(5)
    end

    it "caps the limit rather than returning an unbounded list" do
      result = described_class.call(limit: 9_999).structured_content
      expect(result[:filters_applied][:limit]).to eq(200)
      expect(result[:returned]).to eq(60)
      expect(result[:truncated]).to be(false)
    end

    it "says the default applied even when it did not truncate" do
      Activity.where("started_at < ?", zone.parse("2026-06-14")).delete_all

      expect(payload[:notable]).to include(a_string_matching(/It did not truncate this result/))
    end
  end

  describe "the activity rows" do
    it "returns the curated metric set" do
      run_on("2026-06-10", distance_meters: 12_345.0, duration_seconds: 3_601.4, elevation_gain_meters: 123.6)

      activity = payload[:activities].first
      expect(activity).to include(
        date: "2026-06-10", activity_type: "running", distance_km: 12.35,
        duration_seconds: 3_601, elevation_gain_meters: 124,
        average_pace_per_km: 360.0, tss_score: 60.0
      )
      expect(activity[:started_at]).to eq("2026-06-10T09:00:00-04:00")
    end

    it "keeps the same keys on every row, nulls included" do
      run_on("2026-06-10")
      run_on("2026-06-11", :without_computed_metrics)

      keys = payload[:activities].map(&:keys).uniq
      expect(keys.size).to eq(1)
      expect(payload[:activities].map { |a| a[:tss_score] }).to eq([ nil, 60.0 ])
    end

    it "carries the race a run belongs to, with its target and result" do
      race = create(:race, name: "Spring Half", race_date: Date.new(2026, 6, 7), distance_meters: 21_097,
        target_time_seconds: 5_400, result_time_seconds: 5_512, status: "completed")
      run_on("2026-06-07", race: race)

      expect(payload[:activities].first[:race]).to eq(
        name: "Spring Half", date: "2026-06-07", distance_km: 21.1,
        target_time_seconds: 5_400, result_time_seconds: 5_512
      )
    end

    it "leaves the race null on a training run" do
      run_on("2026-06-10")

      expect(payload[:activities].first[:race]).to be_nil
    end

    # The pipeline strips GPS before delivery and the schema has no column for
    # it. There is nothing to leak, and this pins that.
    it "exposes no route, stream or lap data" do
      run_on("2026-06-10")

      expect(payload[:activities].first.keys).to contain_exactly(
        :date, :started_at, :activity_type, :distance_km, :duration_seconds,
        :average_pace_per_km, :avg_grade_adjusted_pace_per_km, :elevation_gain_meters,
        :average_heart_rate, :tss_score, :efficiency_factor, :grade_adjusted_efficiency_factor,
        :aerobic_decoupling_pct, :pace_cv, :race
      )
    end
  end

  describe "shaping contract" do
    it "reports the matching count alongside the list" do
      run_on("2026-06-10")

      expect(payload.keys).to contain_exactly(
        :filters_applied, :total_matching, :returned, :truncated, :activities, :notable
      )
    end

    it "says plainly when nothing matched" do
      expect(payload[:total_matching]).to eq(0)
      expect(payload[:activities]).to eq([])
      expect(payload[:notable]).to eq([ "No activities match these filters." ])
    end
  end
end
