require "rails_helper"

RSpec.describe Race do
  let!(:runner) { create(:runner, timezone: "America/Toronto") }

  describe "#target_pace_per_km" do
    it "derives goal pace from the target time over the nominal distance" do
      race = build(:race, distance_meters: 42_195, target_time_seconds: 12_600)

      expect(race.target_pace_per_km).to eq(298.6)
    end

    it "is null when no target has been set" do
      expect(build(:race, target_time_seconds: nil).target_pace_per_km).to be_nil
    end
  end

  describe "date handling" do
    # 20:00 in Toronto is already tomorrow in UTC. Race day must not end early
    # because midnight arrived on the server first.
    around do |example|
      travel_to(Time.utc(2026, 6, 15, 1, 0, 0)) { example.run }
    end

    it "keeps a race scheduled for today in the upcoming set" do
      race = create(:race, race_date: Date.new(2026, 6, 14), status: "upcoming")

      expect(described_class.next_race).to eq(race)
      expect(race.days_until).to eq(0)
    end

    it "counts days until from the runner's today" do
      race = create(:race, race_date: Date.new(2026, 6, 21), status: "upcoming")

      expect(race.days_until).to eq(7)
    end
  end
end
