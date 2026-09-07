require "rails_helper"

RSpec.describe Answers::Cache do
  around { |example| with_cache { example.run } }

  describe "matching a question to an answer" do
    it "returns what was written for it" do
      described_class.write_answer("How is his buildup going?", "Well enough.", version: described_class.version)

      expect(described_class.answer_to("How is his buildup going?")).to eq("Well enough.")
    end

    # Visitors are asking the same handful of things in slightly different ways,
    # so matching on typing rather than meaning would throw away most of the hits.
    it "matches regardless of case, surrounding space and spacing" do
      described_class.write_answer("How is his buildup going?", "Well enough.", version: described_class.version)

      expect(described_class.answer_to("  how is HIS  buildup going? ")).to eq("Well enough.")
    end

    it "does not confuse two different questions" do
      described_class.write_answer("How is his buildup going?", "Well enough.", version: described_class.version)

      expect(described_class.answer_to("What is his longest run?")).to be_nil
    end
  end

  describe "invalidation" do
    it "orphans every prior answer when an activity arrives" do
      described_class.write_answer("How is his buildup going?", "Well enough.", version: described_class.version)

      create(:activity)

      expect(described_class.answer_to("How is his buildup going?")).to be_nil
    end

    # A corrected finish time changes what the readiness tools return, and an
    # answer written before it would still be sitting there.
    it "orphans them when a race changes too" do
      race = create(:race)
      described_class.write_answer("How did his last race go?", "He ran 3:58.", version: described_class.version)

      travel_to(1.minute.from_now) { race.update!(result_time_seconds: 14_000) }

      expect(described_class.answer_to("How did his last race go?")).to be_nil
    end

    # The summary is the exception. A new run makes it a run out of date rather
    # than wrong, and the job that replaces it can fail — versioning it would
    # blank the top of the site until the runner next went out.
    it "leaves the standing summary readable until something replaces it" do
      described_class.write_content("Volume has been climbing.")

      create(:activity)

      expect(described_class.content).to eq("Volume has been climbing.")
    end

    it "keeps answers while nothing has changed" do
      create(:activity)
      described_class.write_answer("How is his buildup going?", "Well enough.", version: described_class.version)

      expect(described_class.answer_to("How is his buildup going?")).to eq("Well enough.")
    end

    # The prompt states today's date, and the questions worth caching are asked
    # relative to it. An answer to "what did he run last Sunday" is a different
    # answer a week later even if no run has landed in between.
    it "orphans every answer when the day turns" do
      create(:runner, timezone: "America/Toronto")
      described_class.write_answer("What did he run last Sunday?", "A long run.", version: described_class.version)

      travel_to(1.day.from_now) do
        expect(described_class.answer_to("What did he run last Sunday?")).to be_nil
      end
    end

    # A turn takes long enough for a run to land in the middle of it. The answer
    # was computed on the corpus before that run and belongs to that version,
    # whatever the version is by the time it is written.
    it "files an answer under the version it was asked against, not the current one" do
      create(:activity)
      asked_against = described_class.version
      create(:activity)

      described_class.write_answer("How is his buildup going?", "Well enough.", version: asked_against)

      expect(described_class.answer_to("How is his buildup going?")).to be_nil
      expect(described_class.answer_to("How is his buildup going?", version: asked_against)).to eq("Well enough.")
    end
  end

  describe "the version" do
    it "carries the data version and the runner's day" do
      create(:runner, timezone: "Pacific/Auckland")
      create(:activity)

      travel_to(Time.utc(2026, 9, 5, 20, 0, 0)) do
        expect(described_class.version).to eq("#{described_class.data_version}:2026-09-06")
      end
    end

    it "takes the day from the caller that already holds it" do
      create(:activity)

      expect(described_class.version(Date.new(2026, 9, 1))).to eq("#{described_class.data_version}:2026-09-01")
    end
  end

  describe "the data version" do
    it "reads as empty before anything has been recorded" do
      expect(described_class.data_version).to eq("empty")
    end

    # A backfill writes many activities a second. Truncating to whole seconds
    # would let the second of them leave the first's answers reachable.
    it "carries sub-second precision" do
      create(:activity)

      expect(described_class.data_version).to match(/\.\d{6}Z\z/)
    end

    it "tracks the newest record rather than the newest activity" do
      create(:activity)
      race = travel_to(1.minute.from_now) { create(:race) }

      expect(described_class.data_version).to eq(race.updated_at.utc.iso8601(6))
    end
  end
end
