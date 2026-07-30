require "rails_helper"

RSpec.describe TrainingWindow do
  let!(:runner) { create(:runner, timezone: "America/Toronto") }
  let(:zone) { ActiveSupport::TimeZone["America/Toronto"] }

  around do |example|
    travel_to(Time.utc(2026, 6, 15, 12, 0, 0)) { example.run }
  end

  describe "resolving the range" do
    it "counts both ends of the window" do
      window = described_class.ending(Date.new(2026, 6, 15), days: 28, zone: zone)

      expect(window.from).to eq(Date.new(2026, 5, 19))
      expect(window.to).to eq(Date.new(2026, 6, 15))
      expect(window.days).to eq(28)
    end

    # A run logged at 23:00 local belongs to the day the runner ran it, not to
    # the next day in UTC.
    it "bounds the window by calendar days in the runner's timezone" do
      create(:activity, started_at: zone.parse("2026-06-15 23:30"))

      window = described_class.ending(Date.new(2026, 6, 15), days: 1, zone: zone)
      expect(window.activities.size).to eq(1)
    end

    it "excludes activities on either side of the range" do
      create(:activity, started_at: zone.parse("2026-06-08 10:00"))
      create(:activity, started_at: zone.parse("2026-06-10 10:00"))
      create(:activity, started_at: zone.parse("2026-06-16 10:00"))

      window = described_class.between(Date.new(2026, 6, 9), Date.new(2026, 6, 15), zone: zone)
      expect(window.activities.size).to eq(1)
    end

    it "reports itself so a response carrying its figures also carries the window" do
      create(:activity, started_at: zone.parse("2026-06-14 10:00"))

      window = described_class.ending(Date.new(2026, 6, 15), days: 7, zone: zone)
      expect(window.period).to eq(
        days: 7, from: "2026-06-09", to: "2026-06-15",
        timezone: "America/Toronto", activity_count: 1
      )
    end
  end

  describe "load" do
    subject(:window) { described_class.ending(Date.new(2026, 6, 15), days: 14, zone: zone) }

    it "normalises the total to both a daily and a weekly figure" do
      14.times { |i| create(:activity, started_at: zone.parse("2026-06-15 10:00") - i.days, tss_score: 50.0) }

      expect(window.load).to include(
        total_tss: 700.0, average_daily_tss: 50.0, average_weekly_tss: 350.0
      )
    end

    it "excludes activities the pipeline could not score and says how many" do
      create(:activity, started_at: zone.parse("2026-06-14 10:00"), tss_score: 50.0)
      create(:activity, :without_computed_metrics, started_at: zone.parse("2026-06-13 10:00"))

      expect(window.load).to include(total_tss: 50.0, activities_missing_tss: 1)
    end
  end

  describe "averages" do
    subject(:window) { described_class.ending(Date.new(2026, 6, 15), days: 14, zone: zone) }

    let!(:race) { create(:race, race_date: Date.new(2026, 6, 7), distance_meters: 21_097, status: "completed") }

    before do
      create(:activity, started_at: zone.parse("2026-06-14 10:00"), average_pace_per_km: 360.0)
      create(:activity, started_at: zone.parse("2026-06-13 10:00"), average_pace_per_km: 380.0)
      create(:activity, started_at: zone.parse("2026-06-07 10:00"), average_pace_per_km: 240.0, race: race)
    end

    it "excludes race efforts by default, because a maximal effort is not a training data point" do
      expect(window.mean(:average_pace_per_km, precision: 1))
        .to eq(value: 370.0, sample_size: 2)
    end

    it "includes them when asked, for the sections where a race is real work" do
      expect(window.mean(:average_pace_per_km, precision: 1, scope: :all))
        .to eq(value: 326.7, sample_size: 3)
    end

    it "reports a null average rather than zero when nothing carries the metric" do
      Activity.update_all(average_pace_per_km: nil)

      expect(window.mean(:average_pace_per_km)).to eq(value: nil, sample_size: 0)
    end
  end

  describe "weekly buckets" do
    # 2026-06-15 is a Monday, so a window ending that day starts mid-week.
    subject(:window) { described_class.ending(Date.new(2026, 6, 15), days: 14, zone: zone) }

    it "buckets by ISO week, chronologically" do
      create(:activity, started_at: zone.parse("2026-06-03 10:00"), distance_meters: 8_000, tss_score: 40.0)
      create(:activity, started_at: zone.parse("2026-06-10 10:00"), distance_meters: 12_000, tss_score: 70.0)
      create(:activity, started_at: zone.parse("2026-06-15 10:00"), distance_meters: 5_000, tss_score: 30.0)

      buckets = window.weekly_buckets.map(&:to_h)
      expect(buckets.map { |b| b[:week_start] }).to eq([ "2026-06-01", "2026-06-08", "2026-06-15" ])
      expect(buckets[1]).to include(distance_km: 12.0, tss: 70.0, activity_count: 1, longest_run_km: 12.0)
    end

    # A window that starts or ends mid-week produces partial buckets whose
    # volume is not comparable with a full week's. Saying so beats silently
    # under-counting the ends.
    it "flags the partial weeks at each end rather than clipping them out" do
      buckets = window.weekly_buckets

      expect(buckets.map(&:complete?)).to eq([ false, true, false ])
      expect(buckets.first.days_in_window).to eq(6)
      expect(buckets.last.days_in_window).to eq(1)
    end

    it "reports the full ISO week bounds even for a partial bucket" do
      bucket = window.weekly_buckets.first

      expect(bucket.week_start).to eq(Date.new(2026, 6, 1))
      expect(bucket.week_end).to eq(Date.new(2026, 6, 7))
    end

    it "emits an empty bucket for a week with no training rather than skipping it" do
      create(:activity, started_at: zone.parse("2026-06-15 10:00"))

      buckets = window.weekly_buckets
      expect(buckets.size).to eq(3)
      expect(buckets[1].activity_count).to eq(0)
      expect(buckets[1].distance_km).to eq(0.0)
      expect(buckets[1].longest_run_km).to be_nil
    end

    # The one place an absent value is legitimately zero: a rest day carries no
    # load, which is a different fact from an unscored activity.
    describe "daily load" do
      it "counts rest days as zero so the week's spread is over seven days" do
        create(:activity, started_at: zone.parse("2026-06-08 10:00"), tss_score: 70.0)
        create(:activity, started_at: zone.parse("2026-06-11 10:00"), tss_score: 30.0)

        bucket = window.weekly_buckets[1]
        expect(bucket.daily_tss).to eq([ 70.0, 0.0, 0.0, 30.0, 0.0, 0.0, 0.0 ])
      end

      it "sums two runs on the same day into one day's load" do
        create(:activity, started_at: zone.parse("2026-06-08 07:00"), tss_score: 40.0)
        create(:activity, started_at: zone.parse("2026-06-08 18:00"), tss_score: 25.0)

        expect(window.weekly_buckets[1].daily_tss.first).to eq(65.0)
      end

      it "covers only the in-window days of a partial week" do
        expect(window.weekly_buckets.first.daily_tss.size).to eq(6)
      end
    end
  end

  describe "an empty window" do
    subject(:window) { described_class.ending(Date.new(2026, 6, 15), days: 28, zone: zone) }

    it "aggregates to zeroes and nulls without raising" do
      expect(window).to be_empty
      expect(window.volume).to include(activity_count: 0, total_distance_km: 0.0, longest_run_km: nil)
      expect(window.load).to include(total_tss: 0.0, average_daily_tss: 0.0)
      expect(window.gain_per_km).to be_nil
      expect(window.terrain_cost_seconds_per_km).to be_nil
      expect(window.zones(:hr_zone_distribution)).to eq(zones: nil, activities_contributing: 0)
    end
  end
end
