require "rails_helper"

RSpec.describe AnalyticalTools::GetPaceProgression do
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

  # Three runs inside the bucket that ends `weeks_ago` weeks before today.
  def bucket_of(weeks_ago, count: 3, **attrs)
    count.times do |i|
      run_on(Date.new(2026, 6, 15) - (weeks_ago * 7) - i, **attrs)
    end
  end

  describe "the series" do
    let(:args) { { days: 84, bucket_weeks: 4 } }

    it "buckets the history into equal multi-week periods, oldest first" do
      expect(payload[:series].size).to eq(3)
      expect(payload[:series].map { |b| b[:from] }).to eq([ "2026-03-24", "2026-04-21", "2026-05-19" ])
      expect(payload[:series].last[:to]).to eq("2026-06-15")
      expect(payload[:period]).to include(bucket_weeks: 4, buckets: 3)
    end

    # A short bucket at the recent end would be the one a client reads the
    # current state from, so any clipping lands on the oldest instead.
    it "clips the oldest bucket rather than the most recent one" do
      result = described_class.call(days: 30, bucket_weeks: 4).structured_content

      expect(result[:series].first).to include(from: "2026-05-17", to: "2026-05-18")
      expect(result[:series].last).to include(from: "2026-05-19", to: "2026-06-15")
    end

    it "averages pace and efficiency within each bucket" do
      bucket_of(0, average_pace_per_km: 340.0, avg_grade_adjusted_pace_per_km: 335.0, efficiency_factor: 1.40)
      bucket_of(5, average_pace_per_km: 380.0, avg_grade_adjusted_pace_per_km: 370.0, efficiency_factor: 1.30)

      series = payload[:series]
      expect(series.last).to include(activity_count: 3, sufficient_sample: true)
      expect(series.last[:average_pace_per_km]).to eq(value: 340.0, sample_size: 3)
      expect(series.last[:avg_grade_adjusted_pace_per_km]).to eq(value: 335.0, sample_size: 3)
      expect(series.last[:efficiency_factor]).to eq(value: 1.4, sample_size: 3)
      expect(series[1][:average_pace_per_km][:value]).to eq(380.0)
    end

    it "reports a thin bucket rather than dropping it, so a gap in training stays visible" do
      bucket_of(0, count: 3)
      bucket_of(5, count: 1)

      thin = payload[:series][1]
      expect(thin[:activity_count]).to eq(1)
      expect(thin[:sufficient_sample]).to be(false)
      expect(thin[:average_pace_per_km]).to eq(value: 360.0, sample_size: 1)
      expect(payload[:notable]).to include(a_string_matching(/reported rather than dropped/))
    end

    it "reports an empty bucket as empty rather than omitting the period" do
      bucket_of(0)

      expect(payload[:series].first).to include(activity_count: 0)
      expect(payload[:series].first[:average_pace_per_km]).to eq(value: nil, sample_size: 0)
    end

    it "clamps the window and bucket width rather than rejecting them" do
      result = described_class.call(days: 9_999, bucket_weeks: 99).structured_content

      expect(result[:period][:days]).to eq(730)
      expect(result[:period][:bucket_weeks]).to eq(12)
    end
  end

  describe "the trend" do
    let(:args) { { days: 84, bucket_weeks: 4 } }

    it "reports a negative pace slope when the runner is getting faster" do
      bucket_of(9, avg_grade_adjusted_pace_per_km: 380.0)
      bucket_of(5, avg_grade_adjusted_pace_per_km: 370.0)
      bucket_of(0, avg_grade_adjusted_pace_per_km: 360.0)

      expect(payload[:trend][:avg_grade_adjusted_pace_per_km])
        .to eq(change_per_bucket: -10.0, buckets_used: 3)
      expect(payload[:notable]).to include(a_string_matching(/10\.0s\/km faster per bucket/))
    end

    it "fits the slope through every bucket, not just the first and the last" do
      # Four buckets at 380, 340, 360, 350. Endpoints alone would give
      # (350 - 380) / 3 = -10.0 per bucket; least squares through all four
      # gives -7.0, because the interior buckets carry weight too.
      result = lambda do
        described_class.call(days: 112, bucket_weeks: 4)
          .structured_content.dig(:trend, :avg_grade_adjusted_pace_per_km, :change_per_bucket)
      end

      bucket_of(13, avg_grade_adjusted_pace_per_km: 380.0)
      bucket_of(9, avg_grade_adjusted_pace_per_km: 340.0)
      bucket_of(5, avg_grade_adjusted_pace_per_km: 360.0)
      bucket_of(0, avg_grade_adjusted_pace_per_km: 350.0)

      expect(result.call).to eq(-7.0)
    end

    # Skipping a thin bucket must not compress the axis: the gap is real time,
    # and re-indexing around it would overstate the trend.
    it "keeps a skipped bucket's position in the axis" do
      bucket_of(9, count: 3, avg_grade_adjusted_pace_per_km: 380.0)
      bucket_of(5, count: 1, avg_grade_adjusted_pace_per_km: 300.0)
      bucket_of(0, count: 3, avg_grade_adjusted_pace_per_km: 360.0)

      # Buckets 0 and 2 are usable, 20s apart across two bucket-widths.
      expect(payload[:trend].dig(:avg_grade_adjusted_pace_per_km, :change_per_bucket)).to eq(-10.0)
    end

    it "reports no trend when only one bucket has a sample" do
      bucket_of(0)

      expect(payload[:trend][:avg_grade_adjusted_pace_per_km])
        .to eq(change_per_bucket: nil, buckets_used: 1)
    end

    # The reason both series exist: raw pace improving while the grade-adjusted
    # figure holds flat is a change of routes, not of fitness.
    it "calls out a raw improvement the terrain explains" do
      bucket_of(9, average_pace_per_km: 400.0, avg_grade_adjusted_pace_per_km: 360.0,
        elevation_gain_meters: 400.0)
      bucket_of(5, average_pace_per_km: 380.0, avg_grade_adjusted_pace_per_km: 360.0,
        elevation_gain_meters: 200.0)
      bucket_of(0, average_pace_per_km: 360.0, avg_grade_adjusted_pace_per_km: 360.0,
        elevation_gain_meters: 20.0)

      expect(payload[:notable]).to include(a_string_matching(/raw and grade-adjusted pace trends disagree/i))
      expect(payload[:notable]).to include(a_string_matching(/change of routes rather than of fitness/))
    end
  end

  describe "distance filtering" do
    let(:args) { { days: 56, distance_bucket: "10k" } }

    it "keeps only efforts within tolerance of a standard distance" do
      run_on("2026-06-10", distance_meters: 10_040)
      run_on("2026-06-11", distance_meters: 9_100)
      run_on("2026-06-12", distance_meters: 21_100)
      run_on("2026-06-13", distance_meters: 5_000)

      expect(payload[:series].sum { |b| b[:activity_count] }).to eq(2)
      expect(payload[:filter_applied][:distance_bucket]).to include(
        key: "10k", nominal_distance_km: 10.0, min_distance_km: 9.0, max_distance_km: 11.0
      )
    end

    it "partitions training runs by descriptive band without overlap" do
      run_on("2026-06-10", distance_meters: 15_000)

      medium = described_class.call(days: 56, distance_bucket: "medium").structured_content
      long = described_class.call(days: 56, distance_bucket: "long").structured_content

      expect(medium[:series].sum { |b| b[:activity_count] }).to eq(0)
      expect(long[:series].sum { |b| b[:activity_count] }).to eq(1)
    end

    it "omits an unbounded band's missing edge rather than sending an infinity" do
      filter = described_class.call(days: 56, distance_bucket: "very_long").structured_content[:filter_applied]

      expect(filter[:distance_bucket]).to include(key: "very_long", min_distance_km: 25.0)
      expect(filter[:distance_bucket]).not_to have_key(:max_distance_km)
    end

    it "defaults to every training run" do
      run_on("2026-06-10", distance_meters: 3_000)
      run_on("2026-06-11", distance_meters: 32_000)

      result = described_class.call(days: 56).structured_content
      expect(result[:filter_applied][:mode]).to eq("any")
      expect(result[:series].sum { |b| b[:activity_count] }).to eq(2)
    end

    it "says plainly when nothing matches the filter" do
      run_on("2026-06-10", distance_meters: 5_000)

      expect(payload[:notable]).to include(a_string_matching(/No training runs in the last 56 days match/))
    end
  end

  describe "intensity filtering" do
    let(:args) { { days: 56, intensity: "threshold" } }

    it "classifies a run by the pace zone it spent most of its time in" do
      run_on("2026-06-10", pace_zone_distribution: { "easy" => 20.0, "threshold" => 70.0, "hard" => 10.0 })
      run_on("2026-06-11", pace_zone_distribution: { "easy" => 80.0, "threshold" => 20.0 })

      expect(payload[:series].sum { |b| b[:activity_count] }).to eq(1)
      expect(payload[:filter_applied]).to include(mode: "intensity", intensity: "threshold", available: true)
    end

    # The pipeline only derives pace zones when threshold pace is configured in
    # its environment. Where it is not, an empty series would read as "no
    # training at this intensity", which is a different claim.
    it "says the data is unavailable rather than returning an empty series" do
      run_on("2026-06-10", pace_zone_distribution: nil)
      run_on("2026-06-11", pace_zone_distribution: nil)

      expect(payload[:filter_applied][:available]).to be(false)
      expect(payload[:filter_applied][:note]).to match(/Pace zone data is unavailable/)
      expect(payload[:notable].first).to match(/gap in the source data, not an absence of training/)
    end

    it "counts how many activities could be classified when only some carry zones" do
      run_on("2026-06-10", pace_zone_distribution: { "threshold" => 90.0 })
      run_on("2026-06-11", pace_zone_distribution: nil)

      expect(payload[:filter_applied]).to include(activities_classifiable: 1)
      expect(payload[:filter_applied][:note]).to match(/1 activities in the window carry no pace zone/)
    end

    it "refuses to group by distance and intensity at once" do
      response = described_class.call(distance_bucket: "10k", intensity: "easy")

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to match(/mutually exclusive/)
    end

    it "treats the default distance bucket as no distance filter at all" do
      run_on("2026-06-10", pace_zone_distribution: { "threshold" => 90.0 })

      result = described_class.call(days: 56, distance_bucket: "any", intensity: "threshold")
      expect(result.error?).to be(false)
      expect(result.structured_content[:series].sum { |b| b[:activity_count] }).to eq(1)
    end
  end

  describe "race markers" do
    let(:args) { { days: 56 } }

    let!(:race) do
      create(:race, name: "Spring Half", race_date: Date.new(2026, 6, 7), distance_meters: 21_097,
        result_time_seconds: 5_512, status: "completed")
    end

    before do
      run_on("2026-06-07", race: race, distance_meters: 21_140.0, duration_seconds: 5_512.0,
        average_pace_per_km: 260.7)
      3.times { |i| run_on(Date.new(2026, 6, 10) + i, average_pace_per_km: 360.0) }
    end

    # A race is a best effort. Averaging it into a bucket makes that month look
    # faster than the training was.
    it "excludes the race from the series" do
      recent = payload[:series].last
      expect(recent[:activity_count]).to eq(3)
      expect(recent[:average_pace_per_km][:value]).to eq(360.0)
    end

    it "reports the race separately with its result" do
      expect(payload[:race_markers].first).to include(
        date: "2026-06-07", name: "Spring Half", distance_km: 21.14,
        nominal_distance_km: 21.1, result_time_seconds: 5_512, pace_per_km: 260.7
      )
    end

    it "says the races were set aside" do
      expect(payload[:notable]).to include(a_string_matching(/excluded from the series and reported as race_markers/))
    end

    # A marathon result is context for a 10k progression, so the marker is
    # returned either way and flagged for whether it matched.
    it "flags whether each marker matches the active filter" do
      result = described_class.call(days: 56, distance_bucket: "10k").structured_content

      expect(result[:race_markers].first[:matches_filter]).to be(false)
    end
  end

  describe "shaping contract" do
    it "returns a series and a trend rather than a list of activities" do
      run_on("2026-06-10")

      expect(payload.keys).to contain_exactly(
        :filter_applied, :period, :training_context, :series, :trend, :race_markers, :notable
      )
    end

    it "keeps the same keys on every series row" do
      bucket_of(0)

      expect(payload[:series].map(&:keys).uniq.size).to eq(1)
    end

    it "handles an empty database without raising" do
      expect { payload }.not_to raise_error
      expect(payload[:race_markers]).to eq([])
      expect(payload[:trend][:average_pace_per_km][:buckets_used]).to eq(0)
    end
  end
end
