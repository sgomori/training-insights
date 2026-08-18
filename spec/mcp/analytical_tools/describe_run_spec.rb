require "rails_helper"

RSpec.describe AnalyticalTools::DescribeRun do
  subject(:payload) { described_class.call(**args).structured_content }

  let(:args) { {} }
  let!(:runner) { create(:runner, timezone: "America/Toronto") }
  let(:zone) { ActiveSupport::TimeZone["America/Toronto"] }

  around do |example|
    travel_to(Time.utc(2026, 6, 15, 12, 0, 0)) { example.run }
  end

  def run_on(date, hour: 9, **attrs)
    create(:activity, started_at: zone.parse(date.to_s).change(hour: hour), **attrs)
  end

  def lap_it(activity, distance_meters, pace)
    create(:activity_lap, activity: activity,
                          lap_index: activity.activity_laps.count,
                          distance_meters: distance_meters,
                          duration_seconds: (distance_meters / 1000.0) * pace,
                          average_pace_per_km: pace)
  end

  def steady_run(activity)
    3.times { lap_it(activity, 1_000, 360) }
    lap_it(activity, 400, 355)
    activity
  end

  describe "which activity it describes" do
    it "describes the most recent activity when asked for nothing in particular" do
      run_on("2026-06-01")
      run_on("2026-06-12")

      expect(payload[:activity][:date]).to eq("2026-06-12")
      expect(payload[:selection][:requested]).to eq("most recent activity")
    end

    it "describes the day it was given" do
      run_on("2026-06-01")
      run_on("2026-06-12")

      result = described_class.call(date: "2026-06-01").structured_content
      expect(result[:activity][:date]).to eq("2026-06-01")
    end

    it "bounds the day by the runner's timezone, not the server's" do
      run_on("2026-06-10", hour: 21)

      result = described_class.call(date: "2026-06-10").structured_content
      expect(result[:activity][:date]).to eq("2026-06-10")
    end

    # A double day is common and the response has to be readable a turn later,
    # so the effort that was not described is named rather than dropped.
    it "takes the longest of a double day and names the other" do
      run_on("2026-06-12", hour: 7, distance_meters: 5_000)
      run_on("2026-06-12", hour: 17, distance_meters: 18_000)

      result = described_class.call(date: "2026-06-12").structured_content

      expect(result[:activity][:distance_km]).to eq(18.0)
      expect(result[:selection][:other_activities_that_day].sole[:distance_km]).to eq(5.0)
    end

    it "picks one effort out of a day by its exact start time" do
      morning = run_on("2026-06-12", hour: 7, distance_meters: 5_000)

      result = described_class.call(started_at: morning.started_at.iso8601).structured_content
      expect(result[:activity][:distance_km]).to eq(5.0)
    end

    it "omits the alternatives key when the day held one activity" do
      run_on("2026-06-12")

      expect(payload[:selection]).not_to have_key(:other_activities_that_day)
    end
  end

  describe "when there is nothing to describe" do
    it "says so rather than failing when no activities exist at all" do
      response = described_class.call

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to match(/No activities have been recorded yet/)
    end

    it "names the empty day" do
      run_on("2026-06-01")

      response = described_class.call(date: "2026-06-08")
      expect(response.content.first[:text]).to match(/No activity was recorded on 2026-06-08/)
    end

    it "rejects a date it cannot read" do
      response = described_class.call(date: "last Tuesday")

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to match(/Use YYYY-MM-DD/)
    end

    it "rejects a timestamp it cannot read" do
      response = described_class.call(started_at: "yesterday morning")

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to match(/ISO 8601/)
    end
  end

  describe "the headline figures" do
    it "reports the effort alongside its shape, so the response stands alone" do
      steady_run(run_on("2026-06-12", distance_meters: 12_100.0, duration_seconds: 4_356.0))

      expect(payload[:activity]).to include(distance_km: 12.1, duration_seconds: 4_356, average_pace_per_km: 360.0)
    end

    it "names the race where the effort ran one" do
      race = create(:race, name: "Around the Bay", race_date: Date.new(2026, 6, 12),
                           status: "completed", distance_meters: 30_000, result_time_seconds: 8_100)
      steady_run(run_on("2026-06-12", race: race))

      expect(payload[:activity][:race]).to include(name: "Around the Bay")
      expect(payload[:notable]).to include(a_string_matching(/raced rather than trained/))
    end
  end

  describe "the shape it reads" do
    it "describes an interval session as repeats" do
      activity = run_on("2026-06-12", pace_cv: 0.31)
      2.times { lap_it(activity, 1_000, 360) }
      6.times { lap_it(activity, 1_000, 270); lap_it(activity, 200, 420) }
      lap_it(activity, 1_000, 370)

      expect(payload[:structure][:phases].map { |phase| phase[:kind] }).to eq(%w[warmup repeats cooldown])
      expect(payload[:notable]).to include(a_string_matching(/6 repetitions of about 1.0 km/))
    end

    it "describes an even effort as continuous rather than inventing phases" do
      steady_run(run_on("2026-06-12"))

      expect(payload[:structure][:shape]).to eq("continuous")
    end

    it "reports the shape as unavailable where no laps were recorded" do
      run_on("2026-06-12")

      expect(payload[:structure][:shape]).to eq("unavailable")
      expect(payload[:structure][:explanation]).to match(/No laps were recorded/)
    end
  end

  describe "how the laps should be read" do
    # The caveat that decides everything else: uniform laps mean the phases are
    # kilometre splits, and a rep shorter than the lap cannot appear in them. It
    # sits in the basis rather than among the notable signals, because that is
    # where the reader is already deciding how to read the phases — and because
    # it fires on most of the corpus, which would teach a client to skim notable.
    it "warns in the basis when the watch was lapping automatically" do
      steady_run(run_on("2026-06-12"))

      expect(payload[:structure][:basis]).to match(/lapping automatically/)
    end

    it "stays quiet where the laps were pressed by hand" do
      activity = run_on("2026-06-12")
      lap_it(activity, 1_000, 360)
      lap_it(activity, 400, 270)
      lap_it(activity, 1_600, 350)

      expect(payload[:structure][:basis]).not_to match(/lapping automatically/)
    end

    # Two readings of the same run disagreeing is the finding, not an error.
    it "surfaces a continuous reading that contradicts high pace variability" do
      steady_run(run_on("2026-06-12", pace_cv: 0.28))

      expect(payload[:notable]).to include(a_string_matching(/variation fell inside the laps/))
    end

    it "carries the reading rules for pace variability" do
      steady_run(run_on("2026-06-12", pace_cv: 0.09))

      expect(payload[:pace_variability]).to include(value: 0.09, band: "normal variation")
    end

    it "notes that variability still holds when the laps cannot place it" do
      run_on("2026-06-12", pace_cv: 0.28)

      expect(payload[:pace_variability][:caveats]).to include(a_string_matching(/laps cannot say where/))
    end
  end

  describe "the aerobic signals" do
    it "carries them, so the response answers the obvious follow-up itself" do
      steady_run(run_on("2026-06-12", aerobic_decoupling_pct: 4.2, efficiency_factor: 1.42))

      expect(payload[:aerobic_signals][:aerobic_decoupling_pct]).to include(value: 4.2,
                                                                            band: "well conditioned")
      expect(payload[:aerobic_signals][:efficiency_factor][:value]).to eq(1.42)
    end

    # No other tool can attach this, because no other tool knows the shape of the
    # run the figure was computed over.
    it "warns that they do not apply to a structured session" do
      activity = run_on("2026-06-12", aerobic_decoupling_pct: 11.0)
      2.times { lap_it(activity, 1_000, 360) }
      6.times { lap_it(activity, 1_000, 270); lap_it(activity, 200, 420) }
      lap_it(activity, 1_000, 370)

      expect(payload[:aerobic_signals][:aerobic_decoupling_pct][:caveats])
        .to include(a_string_matching(/not aerobic durability/))
    end

    it "leaves them uncaveated on a steady effort, where they mean what they say" do
      steady_run(run_on("2026-06-12", aerobic_decoupling_pct: 4.2))

      expect(payload[:aerobic_signals][:aerobic_decoupling_pct]).not_to have_key(:caveats)
    end
  end

  describe "how a set of repetitions went" do
    def interval_session(paces)
      activity = run_on("2026-06-12")
      lap_it(activity, 1_000, 360)
      paces.each { |pace| lap_it(activity, 1_000, pace); lap_it(activity, 200, 430) }
      lap_it(activity, 1_000, 380)
      activity
    end

    # A set that faded and a set that negative-split produce identical
    # aggregates. Which of the two it was is the first thing anyone asks about a
    # workout, and it is the thing no aggregation can recover.
    it "reports the reps in the order they were run" do
      interval_session([ 260, 265, 272, 280, 291 ])

      repeats = payload[:structure][:phases].find { |phase| phase[:kind] == "repeats" }
      expect(repeats[:rep_paces_per_km]).to eq([ 260.0, 265.0, 272.0, 280.0, 291.0 ])
    end

    it "calls out a set that faded" do
      interval_session([ 260, 265, 272, 280, 291 ])

      expect(payload[:notable]).to include(a_string_matching(/slowed by 31s per kilometre/))
    end

    it "calls out a set that quickened" do
      interval_session([ 291, 280, 272, 265, 260 ])

      expect(payload[:notable]).to include(a_string_matching(/quickened by 31s per kilometre/))
    end

    it "says so when the reps held together" do
      interval_session([ 270, 271, 269, 272, 270 ])

      expect(payload[:notable]).to include(a_string_matching(/held them within/))
    end

    it "distinguishes a fade from a negative split, which share every aggregate" do
      interval_session([ 260, 265, 272, 280, 291 ])
      faded = payload[:structure][:phases].find { |phase| phase[:kind] == "repeats" }

      expect(faded[:rep_pace_drift_seconds]).to eq(31.0)
      expect(faded[:rep_pace_spread_seconds]).to eq(31.0)
    end
  end

  describe "a sustained block inside a longer run" do
    it "names it, rather than leaving it to be found among the phases" do
      activity = run_on("2026-06-12")
      3.times { lap_it(activity, 1_000, 350) }
      4.times { lap_it(activity, 1_000, 300) }
      3.times { lap_it(activity, 1_000, 355) }
      lap_it(activity, 400, 350)

      expect(payload[:notable]).to include(a_string_matching(/4\.0 km block at 300s\/km/))
    end
  end

  describe "an activity that is not a run" do
    # The default selection is the most recent activity of any type, so this
    # tool can land on a ride while carrying a name that says otherwise.
    it "says so before its pace figures are read as running paces" do
      run_on("2026-06-12", activity_type: "cycling")

      expect(payload[:notable]).to include(a_string_matching(/is a cycling, not a run/))
    end
  end

  describe "selecting by timestamp" do
    # The wire carries whole seconds and the column carries microseconds, so
    # exact equality would reject a value taken straight out of another tool's
    # response.
    it "matches a timestamp that lost its sub-second precision on the way out" do
      run_on("2026-06-12", hour: 7, distance_meters: 5_000)
      Activity.sole.update_columns(started_at: zone.parse("2026-06-12 07:00:00.472"))

      result = described_class.call(started_at: "2026-06-12T07:00:00-04:00").structured_content
      expect(result[:activity][:distance_km]).to eq(5.0)
    end

    it "names the other efforts of that day too" do
      morning = run_on("2026-06-12", hour: 7, distance_meters: 5_000)
      run_on("2026-06-12", hour: 17, distance_meters: 18_000)

      result = described_class.call(started_at: morning.started_at.iso8601).structured_content
      expect(result[:selection][:other_activities_that_day].sole[:distance_km]).to eq(18.0)
    end
  end
end
