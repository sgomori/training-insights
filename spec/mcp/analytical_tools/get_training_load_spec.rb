require "rails_helper"

RSpec.describe AnalyticalTools::GetTrainingLoad do
  subject(:payload) { described_class.call(**args).structured_content }

  let(:args) { {} }
  let!(:runner) { create(:runner, timezone: "America/Toronto") }
  let(:zone) { ActiveSupport::TimeZone["America/Toronto"] }

  # 2026-06-15 is a Monday, so the week of 2026-06-08 is both whole and finished
  # while the week of 2026-06-15 is one day old. Keeping "now" on a Monday is what
  # makes the two conditions distinguishable in these specs.
  around do |example|
    travel_to(example.metadata.fetch(:now, Time.utc(2026, 6, 15, 16, 0, 0))) { example.run }
  end

  # Creates an activity on each named day-offset from `week_start`.
  def train(week_start, weekdays, tss: 50.0, distance_meters: 10_000.0, **attrs)
    weekdays.each do |offset|
      create(:activity, **attrs,
        started_at: zone.parse((week_start + offset).to_s).change(hour: 9),
        tss_score: tss, distance_meters: distance_meters)
    end
  end

  def week_row(week_start)
    payload[:weekly_breakdown].find { |row| row[:week_start] == week_start }
  end

  describe "the window it reports on" do
    it "defaults to six weeks and states the window" do
      expect(payload[:period]).to include(days: 42, from: "2026-05-05", to: "2026-06-15")
    end

    it "clamps a window shorter than a week rather than rejecting it" do
      expect(described_class.call(days: 1).structured_content[:period][:days]).to eq(7)
      expect(described_class.call(days: 9_999).structured_content[:period][:days]).to eq(365)
    end

    it "carries the runner's current load state alongside the period figures" do
      train(Date.new(2026, 6, 8), [ 0, 2, 4 ])

      expect(payload[:training_context]).to include(:acute_7d_tss, :acute_chronic_ratio)
    end
  end

  describe "weekly breakdown" do
    let(:args) { { days: 21 } }

    it "reports one row per ISO week with its own volume and load" do
      train(Date.new(2026, 6, 1), [ 0, 2 ], tss: 40.0, distance_meters: 8_000.0)
      train(Date.new(2026, 6, 8), [ 1, 3, 5 ], tss: 60.0, distance_meters: 12_000.0)

      expect(week_row("2026-06-01")).to include(
        week_end: "2026-06-07", activity_count: 2, distance_km: 16.0, tss: 80.0, longest_run_km: 8.0
      )
      expect(week_row("2026-06-08")).to include(activity_count: 3, tss: 180.0)
    end

    it "reports the week-over-week change between two whole finished weeks" do
      train(Date.new(2026, 6, 1), [ 0, 2 ], tss: 50.0)
      train(Date.new(2026, 6, 8), [ 0, 2, 4 ], tss: 50.0)

      expect(week_row("2026-06-08")[:change_from_previous_pct]).to eq(50.0)
    end

    it "keeps the same keys on every row so the list can be scanned uniformly" do
      train(Date.new(2026, 6, 8), [ 0 ])

      keys = payload[:weekly_breakdown].map(&:keys).uniq
      expect(keys.size).to eq(1)
      expect(keys.first).to include(:monotony, :strain, :change_from_previous_pct,
        :complete_week, :week_in_progress)
    end

    it "emits a row for a week with no training rather than closing the gap" do
      train(Date.new(2026, 6, 1), [ 0 ])

      expect(week_row("2026-06-08")).to include(activity_count: 0, tss: 0.0)
    end
  end

  describe "weeks that are not comparable" do
    # A 10-day window ending Monday 2026-06-15 starts on Saturday 2026-06-06.
    let(:args) { { days: 10 } }

    it "marks a week the window only partly covers" do
      expect(week_row("2026-06-01")).to include(complete_week: false, days_in_window: 2)
      expect(week_row("2026-06-08")).to include(complete_week: true, days_in_window: 7)
    end

    # All seven days of the current week can sit inside the window while the week
    # itself is still being run. Comparing it against finished weeks reports the
    # calendar as a taper, and it would do so once every seven days.
    it "marks the week still in progress even when the window covers it whole" do
      result = described_class.call(days: 14).structured_content
      current = result[:weekly_breakdown].find { |row| row[:week_start] == "2026-06-15" }

      expect(current[:week_in_progress]).to be(true)
      expect(result[:weekly_breakdown].find { |r| r[:week_start] == "2026-06-08" }[:week_in_progress])
        .to be(false)
    end

    # Sunday 2026-06-14: every day of the week of 2026-06-08 is inside the window,
    # but the day itself is not over and the long run may still be ahead.
    it "excludes a week in progress from the derived figures and says why",
      now: Time.utc(2026, 6, 14, 16, 0, 0) do
      train(Date.new(2026, 6, 1), [ 0, 2, 4 ])
      train(Date.new(2026, 6, 8), [ 0, 2, 4 ])

      result = described_class.call(days: 14).structured_content
      expect(result[:weekly_breakdown].find { |r| r[:week_start] == "2026-06-08" }[:monotony]).to be_nil
      expect(result[:notable]).to include(a_string_matching(/is still being run/))
      expect(result[:notable]).to include(a_string_matching(/reads the calendar as a taper/))
    end

    it "does not compare a whole week against a partial one" do
      train(Date.new(2026, 6, 6), [ 0 ], tss: 30.0)
      train(Date.new(2026, 6, 8), [ 0, 2 ], tss: 60.0)

      expect(week_row("2026-06-08")[:change_from_previous_pct]).to be_nil
    end

    it "leaves the derived weekly figures null on a partial week" do
      train(Date.new(2026, 6, 6), [ 0, 1 ])

      expect(week_row("2026-06-01")).to include(monotony: nil, strain: nil)
    end

    it "excludes partial weeks from the block figures and says so" do
      train(Date.new(2026, 6, 6), [ 0, 1 ])
      train(Date.new(2026, 6, 8), [ 0, 2, 4 ])

      expect(payload[:monotony][:sample_size]).to eq(1)
      expect(payload[:notable]).to include(a_string_matching(/fall only partly inside the window/))
    end
  end

  describe "ramp rate" do
    # A 35-day window ending Monday 2026-06-15 covers four whole finished weeks:
    # 2026-05-18, 05-25, 06-01 and 06-08.
    let(:args) { { days: 35 } }

    it "reports the compound weekly growth rate across the window" do
      # 100, 150, 300, 300 TSS. Compound: (300/100) ** (1/3) - 1 = 44.2%.
      train(Date.new(2026, 5, 18), [ 0, 2 ], tss: 50.0)
      train(Date.new(2026, 5, 25), [ 0, 2, 4 ], tss: 50.0)
      train(Date.new(2026, 6, 1), [ 0, 1, 2, 3, 4, 5 ], tss: 50.0)
      train(Date.new(2026, 6, 8), [ 0, 1, 2, 3, 4, 5 ], tss: 50.0)

      ramp = payload[:ramp_rate]
      expect(ramp[:value]).to eq(44.2)
      expect(ramp[:sample_size]).to eq(4)
      expect(ramp[:band]).to eq("aggressive build")
    end

    # The mean of week-over-week ratios is not a rate of growth: it is biased
    # upward by exactly the week-to-week variability a well-structured block has.
    # Here the two figures fall either side of the 10% convention, so reporting
    # the mean would trip the aggressive-build signal on a block that grew at 7.7%
    # a week.
    it "does not report the mean of the weekly changes as the growth rate" do
      # 200, 400, 200, 250 TSS by week.
      train(Date.new(2026, 5, 18), [ 0, 1, 2, 3 ], tss: 50.0)
      train(Date.new(2026, 5, 25), [ 0, 1, 2, 3 ], tss: 100.0)
      train(Date.new(2026, 6, 1), [ 0, 1, 2, 3 ], tss: 50.0)
      train(Date.new(2026, 6, 8), [ 0, 1, 2, 3, 4 ], tss: 50.0)

      ramp = payload[:ramp_rate]
      # Changes of +100%, -50%, +25% average +25%. Compounding 200 to 250 over
      # three steps is (250/200) ** (1/3) - 1 = 7.7%.
      expect(ramp[:mean_of_weekly_changes_pct]).to eq(25.0)
      expect(ramp[:value]).to eq(7.7)
      expect(ramp[:band]).to eq("moderate build")
      expect(payload[:notable]).not_to include(a_string_matching(/aggressive build/))
    end

    it "keeps both figures distinguishable in the caveats" do
      train(Date.new(2026, 5, 18), [ 0, 2 ])
      train(Date.new(2026, 6, 8), [ 0, 2 ])

      expect(payload[:ramp_rate][:caveats]).to include(a_string_matching(/is not a growth rate/))
      expect(payload[:ramp_rate][:guidance]).to match(/compound rate, not the mean/)
    end

    it "reports a negative rate when load is coming down" do
      train(Date.new(2026, 5, 18), [ 0, 1, 2, 3 ], tss: 50.0)
      train(Date.new(2026, 5, 25), [ 0, 1, 2 ], tss: 50.0)
      train(Date.new(2026, 6, 1), [ 0, 1 ], tss: 50.0)
      train(Date.new(2026, 6, 8), [ 0 ], tss: 50.0)

      # 200 down to 50 over three steps: (50/200) ** (1/3) - 1 = -37.0%.
      expect(payload[:ramp_rate][:value]).to eq(-37.0)
      expect(payload[:ramp_rate][:band]).to eq("reducing")
    end

    it "reports no rate at all when the first week of the window carried no load" do
      train(Date.new(2026, 5, 25), [ 0, 2 ], tss: 50.0)
      train(Date.new(2026, 6, 1), [ 0, 2 ], tss: 50.0)
      train(Date.new(2026, 6, 8), [ 0, 2 ], tss: 50.0)

      ramp = payload[:ramp_rate]
      expect(ramp[:value]).to be_nil
      expect(ramp[:caveats]).to include(a_string_matching(/first week of the window carried no load/))
    end

    # A percentage change from zero is undefined, not zero.
    it "excludes a transition out of a zero-load week from the arithmetic mean" do
      train(Date.new(2026, 5, 25), [ 0, 2 ], tss: 50.0)
      train(Date.new(2026, 6, 1), [ 0, 2 ], tss: 50.0)
      train(Date.new(2026, 6, 8), [ 0, 2 ], tss: 50.0)

      expect(payload[:ramp_rate][:caveats]).to include(a_string_matching(/carried no load, which has no defined/))
      expect(payload[:ramp_rate][:mean_of_weekly_changes_pct]).to eq(0.0)
    end

    it "reports no rate with fewer than two whole finished weeks" do
      train(Date.new(2026, 6, 8), [ 0, 2, 4 ])

      short = described_class.call(days: 10).structured_content
      expect(short[:ramp_rate][:value]).to be_nil
      expect(short[:notable]).to include(a_string_matching(/not enough to describe a trend/))
    end

    it "surfaces a sustained build separately from a single hard step up" do
      train(Date.new(2026, 5, 18), [ 0 ], tss: 50.0)
      train(Date.new(2026, 5, 25), [ 0, 1 ], tss: 50.0)
      train(Date.new(2026, 6, 1), [ 0, 1, 2 ], tss: 50.0)
      train(Date.new(2026, 6, 8), [ 0, 1, 2, 3 ], tss: 50.0)

      expect(payload[:notable]).to include(a_string_matching(/3 consecutive weeks of load increase/))
    end

    # A dropped transition must break the run rather than collapsing so two
    # non-adjacent builds count as consecutive.
    it "does not treat builds either side of a zero-load week as consecutive" do
      train(Date.new(2026, 5, 25), [ 0, 1 ], tss: 50.0)
      train(Date.new(2026, 6, 1), [ 0, 1, 2 ], tss: 50.0)
      train(Date.new(2026, 6, 8), [ 0, 1, 2, 3 ], tss: 50.0)

      expect(payload[:notable]).not_to include(a_string_matching(/consecutive weeks of load increase/))
    end
  end

  describe "monotony" do
    let(:args) { { days: 14 } }

    it "counts rest days as zero, because a day with no run carries no load" do
      # 300 TSS across three days: daily load 100,0,100,0,100,0,0.
      # Mean 42.86, population SD 49.49, monotony 0.87. Dropping the four rest
      # days instead would give a mean of 100 against a spread of zero.
      train(Date.new(2026, 6, 8), [ 0, 2, 4 ], tss: 100.0)

      expect(week_row("2026-06-08")[:monotony]).to eq(0.87)
      expect(payload[:monotony][:band]).to eq("varied")
    end

    # The other half of the same distinction, and the half that is easy to lose.
    # A day the runner trained on but whose load the pipeline could not derive is
    # not a rest day, and entering it as a zero moves the week a whole band.
    it "withholds monotony for a week holding a training day it could not score" do
      train(Date.new(2026, 6, 8), [ 0, 1, 2, 3, 4 ], tss: 50.0)
      create(:activity, :without_computed_metrics,
        started_at: zone.parse("2026-06-13").change(hour: 9), distance_meters: 10_000.0)

      row = week_row("2026-06-08")
      expect(row[:activities_missing_tss]).to eq(1)
      expect(row[:monotony]).to be_nil
      expect(row[:strain]).to be_nil
      expect(payload[:monotony][:caveats])
        .to include(a_string_matching(/would put it in the week as a rest day/))
    end

    it "reports a higher figure for a week of near-identical days" do
      # 50 TSS every day: mean 50, SD 0 — and so no defined monotony.
      # Nudging one day breaks the tie and leaves the week monotonous.
      train(Date.new(2026, 6, 8), [ 0, 1, 2, 3, 4, 5 ], tss: 50.0)
      train(Date.new(2026, 6, 8), [ 6 ], tss: 45.0)

      expect(week_row("2026-06-08")[:monotony]).to be > 2.0
      expect(payload[:monotony][:band]).to eq("monotonous")
      expect(payload[:notable]).to include(a_string_matching(/near-identical daily doses/))
    end

    # Seven identical days has a zero spread and no defined monotony. Reporting
    # infinity would look like a real number.
    it "returns null rather than dividing by a zero spread, and says which case it was" do
      train(Date.new(2026, 6, 8), [ 0, 1, 2, 3, 4, 5, 6 ], tss: 50.0)

      expect(week_row("2026-06-08")[:monotony]).to be_nil
      expect(payload[:monotony][:value]).to be_nil
      expect(payload[:monotony][:caveats]).to include(a_string_matching(/did not vary at all/))
    end

    it "distinguishes a rest week from a week whose load did not vary" do
      train(Date.new(2026, 6, 1), [ 0, 2 ])

      result = described_class.call(days: 21).structured_content
      expect(result[:monotony][:caveats]).to include(a_string_matching(/carried no training at all/))
    end

    it "ships the reading guidance and reference bands with the value" do
      train(Date.new(2026, 6, 8), [ 0, 2, 4 ])

      expect(payload[:monotony]).to include(unit: "ratio", direction: "lower_is_better")
      expect(payload[:monotony][:reference_bands]).to include(a_hash_including(label: "monotonous", min: 2.0))
      expect(payload[:monotony][:guidance]).to match(/population standard deviation/)
    end
  end

  describe "strain" do
    let(:args) { { days: 14 } }

    it "multiplies the week's load by its monotony" do
      train(Date.new(2026, 6, 8), [ 0, 2, 4 ], tss: 100.0)

      row = week_row("2026-06-08")
      expect(row[:strain]).to eq((row[:tss] * row[:monotony]).round)
    end

    it "gives no reference bands, because the published ones are in other units" do
      train(Date.new(2026, 6, 8), [ 0, 2, 4 ])

      expect(payload[:strain]).not_to have_key(:reference_bands)
      expect(payload[:strain][:guidance]).to match(/session-RPE/)
    end
  end

  describe "load" do
    let(:args) { { days: 14 } }

    it "reports the window total as both a daily and a weekly figure" do
      train(Date.new(2026, 6, 2), [ 0, 1, 2, 3, 4, 5, 6 ], tss: 50.0)
      train(Date.new(2026, 6, 9), [ 0, 1, 2, 3, 4, 5, 6 ], tss: 50.0)

      expect(payload[:load]).to include(total_tss: 700.0, average_daily_tss: 50.0, average_weekly_tss: 350.0)
    end

    it "says how much load is missing rather than reporting a confident total" do
      train(Date.new(2026, 6, 8), [ 0 ], tss: 50.0)
      create(:activity, :without_computed_metrics, started_at: zone.parse("2026-06-10").change(hour: 9))

      expect(payload[:load][:activities_missing_tss]).to eq(1)
      expect(payload[:notable]).to include(a_string_matching(/every load figure here is understated/))
    end
  end

  describe "shaping contract" do
    it "returns aggregations rather than a list of activities" do
      train(Date.new(2026, 6, 8), [ 0, 2, 4 ])

      expect(payload.keys).to contain_exactly(
        :period, :training_context, :load, :weekly_breakdown,
        :ramp_rate, :monotony, :strain, :notable
      )
    end

    it "handles an empty database without raising" do
      expect { payload }.not_to raise_error
      expect(payload[:load][:total_tss]).to eq(0.0)
      expect(payload[:ramp_rate][:value]).to be_nil
    end

    it "names a whole finished week with no training at all" do
      train(Date.new(2026, 6, 1), [ 0 ])

      expect(described_class.call(days: 21).structured_content[:notable])
        .to include(a_string_matching(/complete week with no training at all/))
    end
  end
end
