require "rails_helper"

RSpec.describe TrainingContext do
  subject(:context) { described_class.current }

  let!(:runner) { create(:runner, timezone: "America/Toronto") }

  around do |example|
    travel_to(Time.utc(2026, 6, 15, 12, 0, 0)) { example.run }
  end

  describe "load windows" do
    it "sums the trailing seven calendar days into the acute figure" do
      10.times { |i| create(:activity, started_at: i.days.ago, tss_score: 50.0) }

      # Seven days including today, not a rolling 168 hours from now.
      expect(context.acute_tss).to eq(350.0)
    end

    it "normalises the 28-day total to a weekly figure" do
      28.times { |i| create(:activity, started_at: i.days.ago, tss_score: 60.0) }

      expect(context.chronic_weekly_tss).to eq(420.0)
      expect(context.acute_chronic_ratio).to be_within(0.05).of(1.0)
    end

    it "returns a null ratio rather than dividing by zero when nothing is scored" do
      create(:activity, :without_computed_metrics, started_at: 2.days.ago)

      expect(context.chronic_weekly_tss).to be_nil
      expect(context.acute_chronic_ratio).to be_nil
    end

    it "ignores activities older than the chronic window" do
      create(:activity, started_at: 40.days.ago, tss_score: 500.0)

      expect(context.chronic_weekly_tss).to be_nil
    end
  end

  describe "the training day streak" do
    it "counts consecutive calendar days rather than activities" do
      create(:activity, started_at: 1.day.ago.change(hour: 7))
      create(:activity, started_at: 1.day.ago.change(hour: 18))
      create(:activity, started_at: 2.days.ago)

      expect(context.consecutive_training_days).to eq(2)
    end

    it "is zero with no history at all" do
      expect(context.consecutive_training_days).to eq(0)
      expect(context.days_since_last_activity).to be_nil
    end

    it "bounds the streak at the lookback rather than scanning all history" do
      (described_class::STREAK_LOOKBACK_DAYS + 20).times { |i| create(:activity, started_at: i.days.ago) }

      expect(context.consecutive_training_days).to eq(described_class::STREAK_LOOKBACK_DAYS + 1)
    end
  end

  describe "rest days" do
    it "counts the days in the last seven with no activity" do
      create(:activity, started_at: 0.days.ago)
      create(:activity, started_at: 3.days.ago)

      expect(context.rest_days_in_last_7).to eq(5)
    end

    it "reports a full week of rest when nothing was recorded" do
      create(:activity, started_at: 20.days.ago)

      expect(context.rest_days_in_last_7).to eq(7)
    end
  end

  describe "history" do
    it "measures the span from the earliest activity, not the requested window" do
      create(:activity, started_at: 5.days.ago)

      expect(context.history_spans_days).to eq(6)
      expect(context.sufficient_history_for_chronic_load?).to be(false)
    end

    it "is zero on an empty database" do
      expect(context.history_spans_days).to eq(0)
    end
  end

  describe "the serialised block" do
    it "carries the caveats that qualify the ratio" do
      7.times { |i| create(:activity, started_at: i.days.ago, tss_score: 50.0) }
      create(:activity, :without_computed_metrics, started_at: 1.day.ago.change(hour: 20))

      caveats = context.to_h.dig(:acute_chronic_ratio, :caveats)
      expect(caveats).to include(a_string_matching(/not yet a true chronic load/))
      expect(caveats).to include(a_string_matching(/1 activity in the last 28 days has no TSS/))
    end

    it "falls back to UTC before a runner is configured" do
      Runner.delete_all

      expect(described_class.current.to_h[:timezone]).to eq("UTC")
    end
  end
end
