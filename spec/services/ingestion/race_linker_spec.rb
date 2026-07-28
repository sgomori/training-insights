require "rails_helper"

RSpec.describe Ingestion::RaceLinker do
  let!(:runner) { create(:runner, timezone: "America/Toronto") }
  let(:race_date) { Date.new(2026, 6, 14) }

  def activity_on(date, hour: 9, **attrs)
    create(:activity,
      started_at: ActiveSupport::TimeZone["America/Toronto"].parse(date.to_s).change(hour: hour),
      **attrs)
  end

  describe "matching an activity to a scheduled race" do
    let!(:race) { create(:race, race_date: race_date, distance_meters: 21_097, status: "upcoming") }

    it "links the activity and completes the race" do
      activity = activity_on(race_date, distance_meters: 21_140.0, duration_seconds: 5_412.4)

      expect(described_class.call(activity)).to eq(race)
      expect(activity.reload.race).to eq(race)
      expect(race.reload).to have_attributes(status: "completed", result_time_seconds: 5_412)
    end

    it "records elapsed rather than moving time, because a race is gun to finish" do
      activity = activity_on(race_date, distance_meters: 21_100.0,
        duration_seconds: 5_400.0, moving_time_seconds: 5_280.0)

      described_class.call(activity)

      expect(race.reload.result_time_seconds).to eq(5_400)
    end

    it "ignores an activity on a different day" do
      activity = activity_on(race_date - 1, distance_meters: 21_100.0)

      expect(described_class.call(activity)).to be_nil
      expect(activity.reload.race).to be_nil
    end

    it "uses the runner's timezone, so a late evening race lands on the right day" do
      activity = activity_on(race_date, hour: 23, distance_meters: 21_100.0)

      expect(described_class.call(activity)).to eq(race)
    end

    it "leaves a cancelled race alone" do
      race.update!(status: "cancelled")
      activity = activity_on(race_date, distance_meters: 21_100.0)

      expect(described_class.call(activity)).to be_nil
    end

    it "does nothing when the activity has no distance to match on" do
      activity = activity_on(race_date, distance_meters: nil)

      expect(described_class.call(activity)).to be_nil
    end
  end

  describe "distinguishing the race from the rest of race day" do
    let!(:race) { create(:race, race_date: race_date, distance_meters: 42_195, status: "upcoming") }

    it "does not mistake a warmup jog for the race" do
      warmup = activity_on(race_date, hour: 7, distance_meters: 3_000.0)

      expect(described_class.call(warmup)).to be_nil
      expect(warmup.reload.race).to be_nil
    end

    it "reassigns the link when a closer match arrives afterwards" do
      # A 36km effort is within tolerance, so it links first.
      near_miss = activity_on(race_date, hour: 7, distance_meters: 36_500.0)
      described_class.call(near_miss)
      expect(near_miss.reload.race).to eq(race)

      actual = activity_on(race_date, hour: 10, distance_meters: 42_310.0)
      described_class.call(actual)

      expect(actual.reload.race).to eq(race)
      expect(near_miss.reload.race).to be_nil
    end

    it "keeps the better match when a worse one arrives afterwards" do
      actual = activity_on(race_date, hour: 10, distance_meters: 42_310.0)
      described_class.call(actual)

      near_miss = activity_on(race_date, hour: 16, distance_meters: 37_000.0)

      expect(described_class.call(near_miss)).to be_nil
      expect(actual.reload.race).to eq(race)
      expect(near_miss.reload.race).to be_nil
    end

    it "picks the nearer race when two are scheduled on the same day" do
      ten_k = create(:race, name: "Morning 10K", race_date: race_date,
        distance_meters: 10_000, status: "upcoming")
      activity = activity_on(race_date, distance_meters: 10_050.0)

      expect(described_class.call(activity)).to eq(ten_k)
    end
  end

  describe "re-running the linker" do
    let!(:race) { create(:race, race_date: race_date, distance_meters: 10_000, status: "upcoming") }

    it "is idempotent on redelivery of the same activity" do
      activity = activity_on(race_date, distance_meters: 10_020.0, duration_seconds: 2_400.0)
      described_class.call(activity)

      expect { described_class.call(activity) }.not_to change { activity.reload.race_id }
      expect(Activity.races.count).to eq(1)
    end

    it "picks up a corrected duration on redelivery" do
      activity = activity_on(race_date, distance_meters: 10_020.0, duration_seconds: 2_400.0)
      described_class.call(activity)

      activity.update!(duration_seconds: 2_390.0)
      described_class.call(activity)

      expect(race.reload.result_time_seconds).to eq(2_390)
    end
  end

  describe ".backfill" do
    it "links a race entered after the day it was run" do
      activity = activity_on(race_date, distance_meters: 10_030.0, duration_seconds: 2_400.0)
      race = create(:race, race_date: race_date, distance_meters: 10_000, status: "upcoming")

      expect(described_class.backfill(race)).to eq(race)
      expect(activity.reload.race).to eq(race)
      expect(race.reload.status).to eq("completed")
    end

    it "returns nil when no activity on that day fits the distance" do
      activity_on(race_date, distance_meters: 3_000.0)
      race = create(:race, race_date: race_date, distance_meters: 42_195, status: "upcoming")

      expect(described_class.backfill(race)).to be_nil
    end

    it "leaves a cancelled race unlinked" do
      activity_on(race_date, distance_meters: 10_000.0)
      race = create(:race, race_date: race_date, distance_meters: 10_000, status: "cancelled")

      expect(described_class.backfill(race)).to be_nil
    end
  end

  describe "the link itself" do
    it "unlinks the activity rather than deleting it when a race is removed" do
      race = create(:race, race_date: race_date, distance_meters: 10_000, status: "upcoming")
      activity = activity_on(race_date, distance_meters: 10_020.0)
      described_class.call(activity)

      race.destroy!

      expect(activity.reload).to be_persisted
      expect(activity.race_id).to be_nil
    end

    it "refuses to link two activities to one race" do
      race = create(:race, race_date: race_date, distance_meters: 10_000, status: "upcoming")
      first = activity_on(race_date, hour: 8, distance_meters: 10_020.0)
      second = activity_on(race_date, hour: 12, distance_meters: 10_030.0)

      first.update!(race: race)

      expect { second.update!(race: race) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
