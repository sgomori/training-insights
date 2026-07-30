require "rails_helper"

RSpec.describe AnalyticalTools::GetRaceReadiness do
  subject(:payload) { described_class.call(**args).structured_content }

  let(:args) { {} }
  let!(:runner) { create(:runner, timezone: "America/Toronto") }
  let(:zone) { ActiveSupport::TimeZone["America/Toronto"] }

  around do |example|
    travel_to(Time.utc(2026, 6, 15, 12, 0, 0)) { example.run }
  end

  def run_on(date, *traits, **attrs)
    create(:activity, *traits, started_at: zone.parse(date.to_s).change(hour: 9), **attrs)
  end

  # A marathon four weeks out, so the buildup is twelve weeks run and four to go.
  let(:marathon) do
    create(:race, name: "Toronto Waterfront", race_date: Date.new(2026, 7, 13),
      distance_meters: 42_195, target_time_seconds: 12_600, status: "upcoming")
  end

  describe "resolving the race" do
    it "defaults to the next upcoming race" do
      marathon

      expect(payload[:race]).to include(
        name: "Toronto Waterfront", date: "2026-07-13", days_until: 28,
        distance_km: 42.2, target_time_seconds: 12_600, target_pace_per_km: 298.6
      )
    end

    it "takes a specific race by id, including one already run" do
      past = create(:race, name: "Spring Half", race_date: Date.new(2026, 4, 12),
        distance_meters: 21_097, result_time_seconds: 5_512, status: "completed")

      result = described_class.call(race_id: past.id).structured_content
      expect(result[:race]).to include(name: "Spring Half", has_happened: true, result_time_seconds: 5_512)
      expect(result[:notable]).to include(a_string_matching(/read it as a review rather than a forecast/))
    end

    it "analyses a hypothetical race from a date and distance" do
      result = described_class.call(race_date: "2026-09-01", race_distance_km: 21.1).structured_content

      expect(result[:race]).to include(status: "hypothetical", distance_km: 21.1, days_until: 78)
      expect(result[:race][:note]).to match(/No target time is set/)
    end

    it "returns a failure rather than an empty response when nothing resolves" do
      response = described_class.call

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to match(/no upcoming race/)
    end

    it "returns a failure on an unknown race id" do
      expect(described_class.call(race_id: 999).error?).to be(true)
    end

    it "returns a failure when only half of a hypothetical race is given" do
      response = described_class.call(race_date: "2026-09-01")

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to match(/needs both race_date and race_distance_km/)
    end

    it "returns a failure on an unreadable hypothetical date" do
      expect(described_class.call(race_date: "September", race_distance_km: 10).error?).to be(true)
    end
  end

  describe "the buildup window" do
    before { marathon }

    it "covers the sixteen weeks before the race, cut off at today" do
      run_on("2026-03-20")
      run_on("2026-06-10")

      expect(payload[:buildup]).to include(
        from: "2026-03-23", to: "2026-06-15", nominal_weeks: 16, days_of_buildup_remaining: 28
      )
      expect(payload[:buildup][:basis]).to match(/28 days away, so the buildup is incomplete/)
    end

    # A race is not part of its own preparation. Counting race day would make
    # race week the peak week of every completed buildup.
    it "ends the day before the race rather than on it" do
      past = create(:race, race_date: Date.new(2026, 5, 10), distance_meters: 42_195, status: "completed")
      run_on("2026-01-10", distance_meters: 5_000)
      run_on("2026-05-09", distance_meters: 20_000)
      run_on("2026-05-10", distance_meters: 42_300, race: past)

      result = described_class.call(race_id: past.id).structured_content
      expect(result[:buildup]).to include(from: "2026-01-18", to: "2026-05-09", days_of_buildup_remaining: 0)
      expect(result[:buildup][:basis]).to match(/cannot count as its own preparation/)
      expect(result[:peak_week][:distance_km]).to eq(20.0)
    end

    it "shortens the window to the available history and says which" do
      run_on("2026-05-01")

      expect(payload[:buildup][:from]).to eq("2026-05-01")
      expect(payload[:buildup][:basis]).to match(/History begins 2026-05-01/)
      expect(payload[:notable]).to include(a_string_matching(/does not reach back a full 16 weeks/))
    end
  end

  describe "long run progression" do
    before { marathon }

    it "reports each week's longest run as a share of race distance" do
      run_on("2026-06-08", distance_meters: 32_000)
      run_on("2026-06-09", distance_meters: 12_000)

      week = payload[:long_run_progression][:by_week].find { |w| w[:week_start] == "2026-06-08" }
      expect(week).to include(longest_run_km: 32.0, pct_of_race_distance: 75.8)
    end

    it "leaves the share null for a week with no runs rather than reporting zero" do
      run_on("2026-06-08", distance_meters: 32_000)

      empty = payload[:long_run_progression][:by_week].find { |w| w[:week_start] == "2026-06-15" }
      expect(empty).to include(longest_run_km: nil, pct_of_race_distance: nil)
    end

    it "names the longest run of the buildup against the race distance" do
      run_on("2026-06-08", distance_meters: 32_000)

      expect(payload[:notable]).to include(a_string_matching(/longest run is 32\.0km, 76% of the 42\.2km race/))
    end
  end

  describe "peak week and taper status" do
    before do
      marathon
      # Peak week of 2026-05-25 at 80km, most recent complete week at 40km.
      4.times { |i| run_on(Date.new(2026, 5, 25) + i, distance_meters: 20_000) }
      2.times { |i| run_on(Date.new(2026, 6, 8) + i, distance_meters: 20_000) }
    end

    it "reports the peak week by distance over complete weeks" do
      expect(payload[:peak_week]).to include(week_start: "2026-05-25", distance_km: 80.0)
    end

    it "reports the latest week against the peak, with a band and no verdict" do
      taper = payload[:taper_status]

      expect(taper).to include(peak_week_start: "2026-05-25", weeks_from_peak: 3)
      expect(taper[:current_week_vs_peak][:value]).to eq(0.0)
      expect(taper[:current_week_vs_peak][:band]).to eq("deep taper or interruption")
      expect(taper[:current_week_vs_peak][:guidance]).to match(/says nothing about whether the taper was/)
    end

    it "caveats a partial most recent week rather than comparing it as a full one" do
      taper = payload[:taper_status]

      expect(taper[:latest_week_start]).to eq("2026-06-15")
      expect(taper[:current_week_vs_peak][:caveats]).to include(a_string_matching(/only 1 day into the window/))
    end

    it "names the drop from the peak as a signal" do
      expect(payload[:notable]).to include(a_string_matching(/against a peak of 80\.0km 3 weeks earlier/))
    end
  end

  describe "race pace work" do
    before { marathon }

    # Goal pace is 298.6s/km, so the 3% band is roughly 290 to 308.
    it "counts training efforts whose grade-adjusted pace sits near goal pace" do
      run_on("2026-06-01", distance_meters: 16_000, avg_grade_adjusted_pace_per_km: 300.0)
      run_on("2026-06-02", distance_meters: 10_000, avg_grade_adjusted_pace_per_km: 295.0)
      run_on("2026-06-03", distance_meters: 20_000, avg_grade_adjusted_pace_per_km: 360.0)

      work = payload[:race_pace_work]
      expect(work).to include(
        target_pace_per_km: 298.6, activities_at_or_near_target: 2,
        total_km_near_target: 26.0, longest_km_near_target: 16.0
      )
    end

    # Grade-adjusted, because race pace on a hill is not race pace.
    it "judges on grade-adjusted pace rather than raw pace" do
      run_on("2026-06-01", distance_meters: 16_000, average_pace_per_km: 300.0,
        avg_grade_adjusted_pace_per_km: 340.0)

      expect(payload[:race_pace_work][:activities_at_or_near_target]).to eq(0)
    end

    it "excludes races from the count, since a race is not race-pace training" do
      other = create(:race, race_date: Date.new(2026, 6, 7), distance_meters: 42_195, status: "completed")
      run_on("2026-06-07", race: other, distance_meters: 42_000, avg_grade_adjusted_pace_per_km: 298.0)

      expect(payload[:race_pace_work][:activities_at_or_near_target]).to eq(0)
    end

    it "says the section is unavailable when the race carries no target time" do
      marathon.update!(target_time_seconds: nil)
      run_on("2026-06-01", avg_grade_adjusted_pace_per_km: 300.0)

      expect(payload[:race_pace_work][:basis]).to match(/no goal pace to compare against/)
      expect(payload[:race_pace_work]).not_to have_key(:activities_at_or_near_target)
      expect(payload[:notable]).to include(a_string_matching(/no goal-pace work could be identified/))
    end

    it "states that only whole activities are counted" do
      run_on("2026-06-01", avg_grade_adjusted_pace_per_km: 400.0)

      expect(payload[:race_pace_work][:basis]).to match(/race-pace finish does not count/)
      expect(payload[:notable]).to include(a_string_matching(/race-pace segments inside longer runs are invisible/))
    end
  end

  describe "aerobic trend" do
    before { marathon }

    it "reports decoupling and grade-adjusted efficiency factor per week" do
      run_on("2026-06-08", aerobic_decoupling_pct: 6.0, grade_adjusted_efficiency_factor: 1.30)
      run_on("2026-06-09", aerobic_decoupling_pct: 4.0, grade_adjusted_efficiency_factor: 1.40)

      week = payload[:aerobic_trend][:decoupling_series].find { |w| w[:week_start] == "2026-06-08" }
      expect(week).to include(value: 5.0, sample_size: 2)

      ef = payload[:aerobic_trend][:grade_adjusted_ef_series].find { |w| w[:week_start] == "2026-06-08" }
      expect(ef[:value]).to eq(1.35)
    end

    it "excludes race efforts from the weekly averages" do
      other = create(:race, race_date: Date.new(2026, 6, 9), distance_meters: 42_195, status: "completed")
      run_on("2026-06-08", aerobic_decoupling_pct: 4.0)
      run_on("2026-06-09", race: other, aerobic_decoupling_pct: 18.0)

      week = payload[:aerobic_trend][:decoupling_series].find { |w| w[:week_start] == "2026-06-08" }
      expect(week).to include(value: 4.0, sample_size: 1)
    end

    it "reports an empty week as a null with a zero sample rather than omitting it" do
      run_on("2026-06-08", aerobic_decoupling_pct: 4.0)

      week = payload[:aerobic_trend][:decoupling_series].find { |w| w[:week_start] == "2026-06-15" }
      expect(week).to include(value: nil, sample_size: 0)
    end
  end

  describe "comparison to past buildups" do
    before { marathon }

    let!(:past_marathon) do
      create(:race, name: "Autumn Marathon", race_date: Date.new(2025, 10, 19), distance_meters: 42_195,
        result_time_seconds: 13_140, status: "completed")
    end

    it "recomputes the buildup figures for each past race of comparable distance" do
      # History reaches back past the nominal window start of 2025-06-29, so the
      # past buildup covers all sixteen weeks.
      run_on("2025-06-29", distance_meters: 5_000)
      # Both in the week beginning 2025-09-08, so it is the peak week at 45km.
      run_on("2025-09-09", distance_meters: 30_000)
      run_on("2025-09-11", distance_meters: 15_000)
      run_on("2025-10-19", distance_meters: 42_300, race: past_marathon)

      comparison = payload[:comparison_to_past_buildups][:past].first
      expect(comparison).to include(
        race_name: "Autumn Marathon", race_date: "2025-10-19", distance_km: 42.2,
        result_time_seconds: 13_140, peak_week_km: 45.0,
        weeks_covered: 16.0, history_covers_full_buildup: true
      )
      expect(comparison[:result_pace_per_km]).to eq(311.4)
    end

    # The target buildup is truncated at the start of history; a past one has to
    # be truncated the same way or the two are not comparable. Dividing 45km by a
    # nominal 16 weeks reports 2.8km a week beside a 45km peak week — both figures
    # correct, the pair of them false — and a client reading that against a
    # current 40km a week sees a fourteenfold build that never happened.
    it "truncates a past buildup at the start of history, as it does the target's" do
      run_on("2025-09-09", distance_meters: 30_000)
      run_on("2025-09-11", distance_meters: 15_000)
      run_on("2025-10-19", distance_meters: 42_300, race: past_marathon)

      comparison = payload[:comparison_to_past_buildups][:past].first
      expect(comparison[:weeks_covered]).to eq(5.7)
      expect(comparison[:history_covers_full_buildup]).to be(false)
      expect(comparison[:average_weekly_km]).to eq(7.9)
      expect(payload[:comparison_to_past_buildups][:basis])
        .to match(/truncated where history does not reach back/)
    end

    # Without the target in the same key shape, the block whose purpose is a
    # side-by-side leaves the client assembling one side of it from other blocks.
    it "reports the target buildup in the same shape as the past ones" do
      run_on("2026-06-08", distance_meters: 30_000)

      comparison = payload[:comparison_to_past_buildups]
      expect(comparison[:this_buildup].keys).to eq(comparison[:past].first.keys)
      expect(comparison[:this_buildup]).to include(
        race_name: "Toronto Waterfront", longest_run_km: 30.0, result_time_seconds: nil
      )
    end

    # The race is reported as the result, not as the buildup's longest run.
    it "leaves the race itself out of the buildup figures it is compared against" do
      run_on("2025-09-09", distance_meters: 30_000)
      run_on("2025-10-19", distance_meters: 42_300, race: past_marathon)

      expect(payload[:comparison_to_past_buildups][:past].first[:longest_run_km]).to eq(30.0)
    end

    it "excludes races of a different distance" do
      create(:race, name: "Spring Half", race_date: Date.new(2026, 4, 12), distance_meters: 21_097,
        result_time_seconds: 5_512, status: "completed")

      expect(payload[:comparison_to_past_buildups][:past].map { |c| c[:race_name] }).to eq([ "Autumn Marathon" ])
    end

    it "falls back to the linked activity's duration when the race has no recorded result" do
      past_marathon.update!(result_time_seconds: nil)
      run_on("2025-10-19", distance_meters: 42_300, duration_seconds: 13_000.0, race: past_marathon)

      expect(payload[:comparison_to_past_buildups][:past].first[:result_time_seconds]).to eq(13_000)
    end

    it "says plainly when there is nothing to compare against" do
      past_marathon.destroy!

      expect(payload[:comparison_to_past_buildups][:past]).to eq([])
      expect(payload[:notable]).to include(a_string_matching(/no previous buildup to compare against/))
    end

    it "does not compare the target race against itself" do
      result = described_class.call(race_id: past_marathon.id).structured_content

      expect(result[:comparison_to_past_buildups][:past].map { |c| c[:race_name] }).not_to include("Autumn Marathon")
    end
  end

  describe "shaping contract" do
    before { marathon }

    it "returns every buildup section" do
      run_on("2026-06-10")

      expect(payload.keys).to contain_exactly(
        :race, :training_context, :buildup, :weekly_volume_trajectory, :long_run_progression,
        :peak_week, :taper_status, :race_pace_work, :aerobic_trend,
        :comparison_to_past_buildups, :notable
      )
    end

    it "returns no readiness verdict" do
      run_on("2026-06-10", distance_meters: 32_000)

      expect(payload.to_json).not_to match(/\b(ready|not ready|on track|behind schedule)\b/i)
    end

    it "handles a buildup with no activities without raising" do
      expect { payload }.not_to raise_error
      expect(payload[:peak_week]).to be_nil
      expect(payload[:notable]).to include(a_string_matching(/No activities recorded in the buildup window/))
    end

    it "flags a race less than a week away" do
      marathon.update!(race_date: Date.new(2026, 6, 18))
      run_on("2026-06-10")

      expect(payload[:notable]).to include(a_string_matching(/3 days away, so the buildup is essentially finished/))
    end
  end
end
