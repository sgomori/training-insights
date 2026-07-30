require "rails_helper"

RSpec.describe AnalyticalTools::ComparePeriods do
  subject(:payload) { described_class.call(**args).structured_content }

  let(:args) { {} }
  let!(:runner) { create(:runner, timezone: "America/Toronto") }
  let(:zone) { ActiveSupport::TimeZone["America/Toronto"] }

  around do |example|
    travel_to(Time.utc(2026, 6, 15, 12, 0, 0)) { example.run }
  end

  def run_on(date, **attrs)
    create(:activity, started_at: zone.parse(date.to_s).change(hour: 9), **attrs)
  end

  describe "resolving the two periods" do
    it "defaults to the last 28 days against the 28 before them" do
      expect(payload[:period_a][:period]).to include(days: 28, from: "2026-05-19", to: "2026-06-15")
      expect(payload[:period_b][:period]).to include(days: 28, from: "2026-04-21", to: "2026-05-18")
      expect(payload[:comparability][:note]).to eq("Periods are adjacent.")
    end

    it "accepts an explicit end date for either period" do
      result = described_class.call(period_a_days: 7, period_a_end_date: "2026-03-31",
        period_b_days: 7, period_b_end_date: "2026-01-31").structured_content

      expect(result[:period_a][:period]).to include(from: "2026-03-25", to: "2026-03-31")
      expect(result[:period_b][:period]).to include(from: "2026-01-25", to: "2026-01-31")
      expect(result[:comparability][:note]).to eq("Periods are disjoint.")
    end

    it "accepts an offset in days as an alternative to a date" do
      result = described_class.call(period_a_days: 7, period_a_offset_days: 0,
        period_b_days: 7, period_b_offset_days: 28).structured_content

      expect(result[:period_a][:period][:to]).to eq("2026-06-15")
      expect(result[:period_b][:period][:to]).to eq("2026-05-18")
    end

    it "returns a failure rather than a silent default on an unreadable date" do
      response = described_class.call(period_a_end_date: "last tuesday")

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to match(/Use YYYY-MM-DD/)
    end

    it "clamps a period length rather than rejecting it" do
      result = described_class.call(period_a_days: 9_999).structured_content

      expect(result[:period_a][:period][:days]).to eq(365)
    end
  end

  describe "the two periods side by side" do
    let(:args) { { period_a_days: 14, period_b_days: 14 } }

    it "reports the same blocks for each" do
      run_on("2026-06-10", distance_meters: 12_000)
      run_on("2026-05-25", distance_meters: 8_000)

      expect(payload[:period_a].keys).to eq(payload[:period_b].keys)
      expect(payload[:period_a][:volume][:total_distance_km]).to eq(12.0)
      expect(payload[:period_b][:volume][:total_distance_km]).to eq(8.0)
    end

    it "carries a per-week distance alongside the total" do
      run_on("2026-06-10", distance_meters: 14_000)

      expect(payload[:period_a][:volume][:distance_km_per_week]).to eq(7.0)
    end

    it "omits the current load state, which belongs to neither period" do
      expect(payload).not_to have_key(:training_context)
    end
  end

  describe "deltas" do
    let(:args) { { period_a_days: 14, period_b_days: 14 } }

    it "reports period_a relative to period_b" do
      3.times { |i| run_on(Date.new(2026, 6, 10) - i, distance_meters: 10_000) }
      3.times { |i| run_on(Date.new(2026, 5, 27) - i, distance_meters: 5_000) }

      expect(payload[:deltas][:total_distance_change_pct]).to eq(100.0)
      expect(payload[:deltas][:activity_count_change]).to eq(0)
    end

    it "leads with the grade-adjusted pace delta and reports the raw one beside it" do
      3.times do |i|
        run_on(Date.new(2026, 6, 10) - i, average_pace_per_km: 350.0, avg_grade_adjusted_pace_per_km: 348.0)
      end
      3.times do |i|
        run_on(Date.new(2026, 5, 27) - i, average_pace_per_km: 380.0, avg_grade_adjusted_pace_per_km: 350.0)
      end

      deltas = payload[:deltas]
      expect(deltas.keys.first(3)).to eq([ :note, :volume_basis, :grade_adjusted_pace_change_seconds_per_km ])
      expect(deltas[:grade_adjusted_pace_change_seconds_per_km]).to eq(-2.0)
      expect(deltas[:pace_change_seconds_per_km]).to eq(-30.0)
    end

    it "calls out a raw improvement the terrain explains" do
      3.times do |i|
        run_on(Date.new(2026, 6, 10) - i, average_pace_per_km: 350.0, avg_grade_adjusted_pace_per_km: 348.0)
      end
      3.times do |i|
        run_on(Date.new(2026, 5, 27) - i, average_pace_per_km: 380.0, avg_grade_adjusted_pace_per_km: 350.0)
      end

      expect(payload[:notable]).to include(a_string_matching(/pace deltas disagree/))
    end

    it "compares efficiency factor and decoupling too" do
      3.times { |i| run_on(Date.new(2026, 6, 10) - i, efficiency_factor: 1.40, aerobic_decoupling_pct: 3.0) }
      3.times { |i| run_on(Date.new(2026, 5, 27) - i, efficiency_factor: 1.30, aerobic_decoupling_pct: 8.0) }

      deltas = payload[:deltas]
      expect(deltas[:efficiency_factor_change]).to eq(0.1)
      expect(deltas[:aerobic_decoupling_change_pct_points]).to eq(-5.0)
    end

    # A race in one period would move every average by more than a training
    # change would, so both sides compare training efforts only.
    it "keeps race efforts out of the aerobic deltas while counting them in volume" do
      race = create(:race, race_date: Date.new(2026, 6, 7), distance_meters: 21_097, status: "completed")
      run_on("2026-06-07", race: race, average_pace_per_km: 240.0, distance_meters: 21_100)
      3.times { |i| run_on(Date.new(2026, 6, 10) - i, average_pace_per_km: 360.0) }
      3.times { |i| run_on(Date.new(2026, 5, 27) - i, average_pace_per_km: 360.0) }

      expect(payload[:deltas][:pace_change_seconds_per_km]).to eq(0.0)
      expect(payload[:comparability][:race_efforts]).to eq(period_a: 1, period_b: 0)
      expect(payload[:period_a][:volume][:activity_count]).to eq(4)
    end
  end

  describe "suppression" do
    let(:args) { { period_a_days: 14, period_b_days: 14 } }

    it "names which side was too thin rather than returning a bare null" do
      run_on("2026-06-10", average_pace_per_km: 350.0)
      3.times { |i| run_on(Date.new(2026, 5, 27) - i, average_pace_per_km: 380.0) }

      deltas = payload[:deltas]
      expect(deltas[:pace_change_seconds_per_km]).to be_nil
      expect(deltas[:suppressed][:average_pace_per_km]).to match(/period_a \(1\)/)
      expect(deltas[:suppressed][:average_pace_per_km]).not_to match(/period_b/)
    end

    it "names both sides when both are thin" do
      run_on("2026-06-10", average_pace_per_km: 350.0)
      run_on("2026-05-27", average_pace_per_km: 380.0)

      expect(payload[:deltas][:suppressed][:average_pace_per_km]).to match(/period_a \(1\) and period_b \(1\)/)
    end

    it "suppresses a metric independently of the ones that have a sample" do
      3.times { |i| run_on(Date.new(2026, 6, 10) - i, average_pace_per_km: 350.0, efficiency_factor: nil) }
      3.times { |i| run_on(Date.new(2026, 5, 27) - i, average_pace_per_km: 380.0, efficiency_factor: 1.30) }

      deltas = payload[:deltas]
      expect(deltas[:pace_change_seconds_per_km]).to eq(-30.0)
      expect(deltas[:efficiency_factor_change]).to be_nil
      expect(deltas[:suppressed]).to have_key(:efficiency_factor)
    end

    it "omits the suppressed block entirely when nothing was suppressed" do
      3.times { |i| run_on(Date.new(2026, 6, 10) - i) }
      3.times { |i| run_on(Date.new(2026, 5, 27) - i) }

      expect(payload[:deltas]).not_to have_key(:suppressed)
    end

    it "reports the count of suppressed deltas as a signal" do
      run_on("2026-06-10")

      expect(payload[:notable]).to include(a_string_matching(/suppressed rather than reported as null/))
    end
  end

  describe "windows of unequal length" do
    let(:args) { { period_a_days: 28, period_b_days: 14 } }

    before do
      # 28 days at 10km every other day against 14 days of the same rate: the
      # totals differ, the per-week figures do not.
      14.times { |i| run_on(Date.new(2026, 6, 15) - (i * 2), distance_meters: 10_000) }
      7.times { |i| run_on(Date.new(2026, 5, 18) - (i * 2), distance_meters: 10_000) }
    end

    it "suppresses the total-based deltas, which say more about window size than training" do
      deltas = payload[:deltas]
      expect(deltas[:total_distance_change_pct]).to be_nil
      expect(deltas[:suppressed][:total_distance_change_pct]).to match(/28 and 14 days long/)
    end

    it "normalises volume and load to per-week figures instead" do
      expect(payload[:deltas][:weekly_distance_change_pct]).to eq(0.0)
      expect(payload[:deltas][:volume_basis]).to match(/Read the per-week deltas/)
    end

    it "still compares the averages, which are length-independent" do
      expect(payload[:deltas][:pace_change_seconds_per_km]).to eq(0.0)
    end

    it "says the lengths differ" do
      expect(payload[:comparability][:equal_length]).to be(false)
      expect(payload[:notable]).to include(a_string_matching(/unequal length \(28 vs 14 days\)/))
    end
  end

  describe "overlapping windows" do
    # Two 28-day windows a fortnight apart share 14 days.
    let(:args) { { period_a_offset_days: 0, period_b_offset_days: 14 } }

    it "allows the comparison but flags the shared days" do
      run_on("2026-06-10")

      expect(payload[:comparability][:overlap_days]).to eq(14)
      expect(payload[:notable]).to include(a_string_matching(/overlap by 14 days/))
      expect(payload[:notable]).to include(a_string_matching(/usually unintentional/))
    end

    it "reports no overlap for adjacent windows" do
      expect(described_class.call.structured_content[:comparability][:overlap_days]).to eq(0)
    end
  end

  describe "an empty period" do
    let(:args) { { period_a_days: 14, period_b_days: 14 } }

    it "says the side is empty rather than emitting deltas against nothing" do
      3.times { |i| run_on(Date.new(2026, 6, 10) - i) }

      expect(payload[:notable]).to include(a_string_matching(/period_b .* contains no activities/))
      expect(payload[:deltas][:total_distance_change_pct]).to be_nil
    end

    it "handles both sides empty without raising" do
      expect { payload }.not_to raise_error
      expect(payload[:notable].size).to be >= 2
    end
  end

  describe "shaping contract" do
    it "returns paired aggregations rather than a list of activities" do
      create_list(:activity, 3)

      expect(payload.keys).to contain_exactly(:period_a, :period_b, :deltas, :comparability, :notable)
      expect(payload[:period_a].keys).to contain_exactly(
        :period, :volume, :terrain, :load, :intensity_distribution, :aerobic_signals
      )
    end
  end
end
