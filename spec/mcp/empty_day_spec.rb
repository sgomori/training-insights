require "rails_helper"

RSpec.describe EmptyDay do
  let!(:runner) { create(:runner, timezone: "America/Toronto") }
  let(:zone) { ActiveSupport::TimeZone["America/Toronto"] }

  around do |example|
    travel_to(Time.utc(2026, 6, 15, 12, 0, 0)) { example.run }
  end

  def run_on(date, **attrs)
    create(:activity, started_at: zone.parse(date.to_s).change(hour: 9), **attrs)
  end

  def surroundings_of(date)
    described_class.new(Date.parse(date), zone)
  end

  describe "the neighbours of the day" do
    it "names both with the gap to each and which side it lies" do
      run_on("2025-03-02", distance_meters: 9_000)
      run_on("2026-03-02", distance_meters: 9_000)
      run_on("2026-06-12")

      prose = surroundings_of("2025-06-08").to_prose

      expect(prose).to include("98 days before, on 2025-03-02 (9.0 km, running) and 267 days after, on 2026-03-02 (9.0 km, running)")
      expect(surroundings_of("2025-06-08").to_h).to include(
        nearest_before: hash_including(days_before: 98), nearest_after: hash_including(days_after: 267)
      )
    end

    # The most recent activity has already been named as the anchor; reading
    # it out a second time as the nearest neighbour says nothing new.
    it "does not name the latest activity twice" do
      run_on("2026-06-12", distance_meters: 8_000)

      prose = surroundings_of("2026-06-13").to_prose

      expect(prose).to eq("Today is 2026-06-15 and the most recent activity was on 2026-06-12 (8.0 km, running).")
      expect(surroundings_of("2026-06-13").to_h).not_to have_key(:nearest_before)
    end

    it "uses the singular for a single day" do
      run_on("2026-06-07")
      run_on("2026-06-12")

      expect(surroundings_of("2026-06-08").to_prose).to include("1 day before, on 2026-06-07")
    end
  end

  describe "the same day in other years" do
    # Seven candidate years would bury a wrong year rather than expose it.
    it "looks at the years either side of the requested one and the current one" do
      %w[2019 2022 2023 2024 2026].each { |year| run_on("#{year}-06-08") }

      dates = surroundings_of("2023-06-08").to_h[:same_day_other_years].map { |entry| entry[:date] }

      expect(dates).to eq(%w[2022-06-08 2024-06-08 2026-06-08])
    end

    it "takes the longest effort where the day held several" do
      run_on("2026-06-08", distance_meters: 5_000)
      create(:activity, started_at: zone.parse("2026-06-08").change(hour: 17), distance_meters: 18_000)

      expect(surroundings_of("2025-06-08").to_h[:same_day_other_years].sole[:distance_km]).to eq(18.0)
    end

    it "names the activity type, so a ride is not offered as a run" do
      run_on("2026-06-08", activity_type: "cycling", distance_meters: 42_000)

      expect(surroundings_of("2025-06-08").to_prose).to include("2026-06-08 (42.0 km, cycling)")
    end
  end

  it "omits a distance the activity does not carry" do
    run_on("2026-06-12", distance_meters: nil)

    expect(surroundings_of("2026-06-08").to_prose).to include("2026-06-12 (running)")
    expect(surroundings_of("2026-06-08").to_h[:most_recent_activity]).to eq(date: "2026-06-12", activity_type: "running")
  end
end
