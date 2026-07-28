require "rails_helper"

RSpec.describe Races::Sync do
  let!(:runner) { create(:runner, timezone: "America/Toronto") }
  let(:path) { Rails.root.join("tmp/races_spec.yml") }

  def write(content)
    path.dirname.mkpath
    path.write(content)
  end

  def sync(dry_run: false)
    described_class.call(path: path, dry_run: dry_run)
  end

  after { path.delete if path.exist? }

  describe "applying the declared calendar" do
    it "creates a race from a declared entry" do
      write(<<~YAML)
        - name: Toronto Waterfront Marathon
          race_date: 2026-10-18
          distance_meters: 42195
          target_time_seconds: 12600
      YAML

      result = sync

      expect(result).to be_ok
      expect(result.created).to contain_exactly("Toronto Waterfront Marathon (2026-10-18)")
      expect(Race.sole).to have_attributes(
        name: "Toronto Waterfront Marathon",
        race_date: Date.new(2026, 10, 18),
        distance_meters: 42_195,
        target_time_seconds: 12_600,
        status: "upcoming"
      )
    end

    it "is idempotent" do
      write(<<~YAML)
        - name: Spring Half
          race_date: 2026-04-26
          distance_meters: 21097
      YAML

      sync
      result = sync

      expect(result.created).to be_empty
      expect(result.unchanged).to contain_exactly("Spring Half (2026-04-26)")
      expect(Race.count).to eq(1)
    end

    it "updates a declared column and names what changed" do
      write(<<~YAML)
        - name: Spring Half
          race_date: 2026-04-26
          distance_meters: 21097
          target_time_seconds: 6000
      YAML
      sync

      write(<<~YAML)
        - name: Spring Half
          race_date: 2026-04-26
          distance_meters: 21097
          target_time_seconds: 5700
      YAML
      result = sync

      expect(result.updated).to contain_exactly("Spring Half (2026-04-26): target_time_seconds")
      expect(Race.sole.target_time_seconds).to eq(5_700)
    end

    it "takes a race off the schedule when the file cancels it" do
      write(<<~YAML)
        - name: Spring Half
          race_date: 2026-04-26
          distance_meters: 21097
          status: cancelled
      YAML

      sync

      expect(Race.sole.status).to eq("cancelled")
    end

    it "treats a changed date as a new race rather than moving the old one" do
      write("- {name: Spring Half, race_date: 2026-04-26, distance_meters: 21097}")
      sync

      write("- {name: Spring Half, race_date: 2026-05-03, distance_meters: 21097}")
      sync

      expect(Race.pluck(:race_date)).to contain_exactly(Date.new(2026, 4, 26), Date.new(2026, 5, 3))
    end

    it "accepts an empty calendar without complaint" do
      write("[]")

      expect(sync).to be_ok
      expect(Race.count).to eq(0)
    end
  end

  describe "protecting derived state" do
    let(:race_date) { Date.new(2026, 6, 14) }

    before do
      write(<<~YAML)
        - name: Beaches Ten
          race_date: 2026-06-14
          distance_meters: 10000
      YAML
    end

    # The whole point of restricting what the file owns: a re-sync after race
    # day must not reopen a completed race or discard its result.
    it "leaves the result and completed status alone on a re-sync" do
      sync
      race = Race.sole
      create(:activity,
        started_at: ActiveSupport::TimeZone["America/Toronto"].parse(race_date.to_s).change(hour: 9),
        distance_meters: 10_030.0, duration_seconds: 2_400.0).tap { |a| Ingestion::RaceLinker.call(a) }

      expect(race.reload.status).to eq("completed")

      sync

      expect(race.reload).to have_attributes(status: "completed", result_time_seconds: 2_400)
      expect(race.activity).to be_present
    end

    it "refuses an entry that tries to declare a race completed" do
      write(<<~YAML)
        - name: Beaches Ten
          race_date: 2026-06-14
          distance_meters: 10000
          status: completed
      YAML

      result = sync

      expect(result).not_to be_ok
      expect(result.errors.first).to match(/only upcoming or cancelled may be declared/)
      expect(Race.count).to eq(0)
    end

    it "never deletes a race the file stopped mentioning" do
      sync
      write("[]")

      result = sync

      expect(Race.count).to eq(1)
      expect(result.unmanaged).to contain_exactly("Beaches Ten (2026-06-14)")
    end
  end

  describe "linking races to activities already ingested" do
    it "backfills a race entered after the day it was run" do
      create(:activity,
        started_at: ActiveSupport::TimeZone["America/Toronto"].parse("2026-06-14").change(hour: 9),
        distance_meters: 10_030.0, duration_seconds: 2_400.0)

      write(<<~YAML)
        - name: Beaches Ten
          race_date: 2026-06-14
          distance_meters: 10000
      YAML

      result = sync

      expect(result.linked).to contain_exactly("Beaches Ten (2026-06-14)")
      expect(Race.sole.activity).to be_present
    end

    it "does not link during a dry run" do
      create(:activity,
        started_at: ActiveSupport::TimeZone["America/Toronto"].parse("2026-06-14").change(hour: 9),
        distance_meters: 10_030.0)
      write("- {name: Beaches Ten, race_date: 2026-06-14, distance_meters: 10000}")

      result = sync(dry_run: true)

      expect(result.linked).to be_empty
      expect(Race.count).to eq(0)
    end
  end

  describe "a dry run" do
    it "reports what would change without writing" do
      write("- {name: Spring Half, race_date: 2026-04-26, distance_meters: 21097}")

      result = sync(dry_run: true)

      expect(result.created).to contain_exactly("Spring Half (2026-04-26)")
      expect(Race.count).to eq(0)
    end
  end

  describe "rejecting a bad file" do
    it "reports every problem at once rather than stopping at the first" do
      write(<<~YAML)
        - name: Missing Distance
          race_date: 2026-04-26
        - name: Bad Date
          race_date: not-a-date
          distance_meters: 10000
        - name: Unknown Key
          race_date: 2026-05-01
          distance_meters: 10000
          goal: sub-40
      YAML

      result = sync

      expect(result.errors.size).to eq(3)
      expect(result.errors[0]).to match(/entry 1 is missing distance_meters/)
      expect(result.errors[1]).to match(/entry 2 has an unparseable race_date/)
      expect(result.errors[2]).to match(/entry 3 has unknown key: goal/)
    end

    it "writes nothing when any entry is invalid" do
      write(<<~YAML)
        - name: Good One
          race_date: 2026-04-26
          distance_meters: 21097
        - name: Bad One
          race_date: 2026-05-01
      YAML

      result = sync

      expect(result).not_to be_ok
      expect(result.created).to be_empty
      expect(Race.count).to eq(0)
    end

    it "rolls back a valid entry when a later one fails to save" do
      write(<<~YAML)
        - name: Good One
          race_date: 2026-04-26
          distance_meters: 21097
        - name: Zero Distance
          race_date: 2026-05-01
          distance_meters: 0
      YAML

      result = sync

      expect(result).not_to be_ok
      expect(result.errors.first).to match(/could not be saved/)
      expect(Race.count).to eq(0)
    end

    it "reports malformed YAML rather than raising" do
      write("- name: [unclosed")

      result = sync

      expect(result).not_to be_ok
      expect(result.errors.first).to match(/not valid YAML/)
    end

    it "reports a file that is not a list" do
      write("name: Spring Half")

      expect(sync.errors.first).to match(/must contain a list of races/)
    end

    it "reports a missing file rather than silently doing nothing" do
      expect(described_class.call(path: Rails.root.join("tmp/nope.yml")).errors.first)
        .to match(/does not exist/)
    end
  end
end
