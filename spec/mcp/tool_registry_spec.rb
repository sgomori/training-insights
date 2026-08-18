require "rails_helper"

RSpec.describe ToolRegistry do
  # The registry is the wire contract. External MCP clients see exactly this
  # list, so a rename or a removal is a breaking change and should fail here
  # before it reaches one.
  describe "the exposed tool set" do
    it "exposes the v1 inventory and nothing else" do
      expect(described_class.tools.map(&:name_value)).to contain_exactly(
        "get_recent_activity_summary",
        "get_training_load",
        "compare_periods",
        "get_activities",
        "get_training_block_summary",
        "get_pace_progression",
        "get_personal_records",
        "get_race_readiness",
        "suggest_next_run",
        "describe_run"
      )
    end

    it "gives every tool a description a client can choose from" do
      described_class.tools.each do |tool|
        expect(tool.description).to be_present, "#{tool.name_value} has no description"
        expect(tool.description.length).to be > 100, "#{tool.name_value} has a thin description"
      end
    end

    it "declares every tool read-only, so no client treats a call as a mutation" do
      described_class.tools.each do |tool|
        annotations = tool.annotations_value.to_h

        expect(annotations).to include(
          readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false
        ), "#{tool.name_value} is not annotated read-only"
      end
    end

    it "gives every tool an input schema with no required arguments" do
      described_class.tools.each do |tool|
        schema = tool.input_schema.to_h

        expect(schema[:properties]).to be_present, "#{tool.name_value} has no documented arguments"
        expect(schema.fetch(:required, [])).to be_empty,
          "#{tool.name_value} requires arguments, so a client cannot call it without knowing the corpus"
      end
    end
  end

  describe "instructions" do
    it "carries the cross-tool reading rules, delivered on every initialize" do
      expect(described_class::INSTRUCTIONS).to match(/seconds per kilometre/)
      expect(described_class::INSTRUCTIONS).to match(/grade-adjusted/)
      expect(described_class::INSTRUCTIONS).to match(/training_context/)
      expect(described_class::INSTRUCTIONS).to match(/Race efforts count fully/)
    end

    # The privacy guarantee is structural — the schema has no column for a route.
    # Saying so up front stops a client asking for what cannot exist.
    it "states that no route data and no stream access exist" do
      expect(described_class::INSTRUCTIONS).to match(/No route or GPS data/)
      expect(described_class::INSTRUCTIONS).to match(/best segment within a run/)
    end
  end

  describe "the server it builds" do
    it "names itself and carries the instructions and tools" do
      server = described_class.server

      expect(server).to be_a(MCP::Server)
      expect(server.name).to eq("training-insights")
    end
  end

  describe "every registered tool" do
    let!(:runner) { create(:runner, timezone: "America/Toronto") }

    around do |example|
      travel_to(Time.utc(2026, 6, 15, 12, 0, 0)) { example.run }
    end

    # A tool that raises on an empty corpus is a tool that breaks on a fresh
    # deployment, which is exactly when a reviewer would first call it.
    it "answers on an empty database without raising" do
      described_class.tools.each do |tool|
        expect { tool.call(server_context: nil) }.not_to raise_error,
          "#{tool.name_value} raised on an empty database"
      end
    end

    it "answers on a corpus of one activity without raising" do
      create(:activity, started_at: 1.day.ago)

      described_class.tools.each do |tool|
        expect { tool.call(server_context: nil) }.not_to raise_error,
          "#{tool.name_value} raised on a single activity"
      end
    end

    it "answers when every computed metric is null" do
      create(:activity, :without_computed_metrics, started_at: 1.day.ago)
      create(:activity, :without_computed_metrics, started_at: 3.days.ago)

      described_class.tools.each do |tool|
        expect { tool.call(server_context: nil) }.not_to raise_error,
          "#{tool.name_value} raised on activities with no computed metrics"
      end
    end

    # JSON has no representation for an infinity or a NaN, so a division that
    # produced one would fail at serialisation rather than in the arithmetic.
    it "returns a payload that serialises to JSON" do
      create(:activity, started_at: 1.day.ago, duration_seconds: 0.0, distance_meters: 0.0)
      create(:activity, started_at: 2.days.ago)

      described_class.tools.each do |tool|
        response = tool.call(server_context: nil)
        next if response.error?

        expect { JSON.generate(response.structured_content) }.not_to raise_error,
          "#{tool.name_value} produced a payload that will not serialise"
      end
    end
  end
end
