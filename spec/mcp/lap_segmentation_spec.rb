require "rails_helper"

RSpec.describe LapSegmentation do
  subject(:result) { described_class.call(laps) }

  # Laps are built as plain values rather than records: the segmentation reads
  # five attributes and touches no association, and driving it from the database
  # would only slow the examples down.
  Lap = Struct.new(:lap_index, :distance_meters, :duration_seconds, :average_pace_per_km, :average_heart_rate)

  def lap(distance_meters, pace, heart_rate: 145)
    @index = @index.to_i
    Lap.new(@index, distance_meters, (distance_meters / 1000.0) * pace, pace, heart_rate).tap { @index += 1 }
  end

  def reps(count, distance:, pace:, recovery_distance: 200, recovery_pace: 420)
    Array.new(count) { [ lap(distance, pace), lap(recovery_distance, recovery_pace) ] }.flatten
  end

  describe "a run with no shape to read" do
    context "when the activity has no laps" do
      let(:laps) { [] }

      it "reports the shape as unavailable rather than empty" do
        expect(result[:shape]).to eq("unavailable")
        expect(result[:phases]).to be_empty
      end

      it "says why, so the absence is not mistaken for an even effort" do
        expect(result[:explanation]).to match(/No laps were recorded/)
      end
    end

    context "when fewer than three laps are usable" do
      let(:laps) { [ lap(1_000, 360), lap(1_000, 300) ] }

      it "declines to describe a shape from two laps" do
        expect(result[:shape]).to eq("unavailable")
        expect(result[:explanation]).to match(/too few to describe a shape/)
      end
    end

    context "when laps are missing distance or duration" do
      let(:laps) do
        [ lap(1_000, 360), lap(1_000, 360), lap(1_000, 360), lap(1_000, 360) ].tap do |list|
          list[1].distance_meters = nil
          list[2].duration_seconds = nil
        end
      end

      it "drops them rather than guessing, and counts them in the basis" do
        expect(result[:basis]).to match(/2 skipped for missing distance or duration/)
      end
    end
  end

  describe "an even effort" do
    let(:laps) { Array.new(6) { |i| lap(1_000, 358 + (i.even? ? 4 : 0)) } }

    it "reads as continuous rather than as six phases" do
      expect(result[:shape]).to eq("continuous")
      expect(result[:phases].size).to eq(1)
    end

    it "explains the reading" do
      expect(result[:explanation]).to match(/one pace throughout/)
    end
  end

  describe "a session of repeats" do
    let(:laps) { [ lap(1_000, 360), lap(1_000, 360) ] + reps(6, distance: 1_000, pace: 270) + [ lap(1_000, 370) ] }

    it "collapses the alternation into one repeats phase" do
      expect(result[:phases].map { |phase| phase[:kind] }).to eq(%w[warmup repeats cooldown])
    end

    it "reports the repetition rather than the laps behind it" do
      repeats = result[:phases].find { |phase| phase[:kind] == "repeats" }

      expect(repeats).to include(reps: 6, rep_distance_km: 1.0, rep_pace_per_km: 270.0, recovery_seconds: 84)
    end

    it "reports how tightly the reps held together" do
      expect(result[:phases][1][:rep_pace_spread_seconds]).to eq(0.0)
    end

    it "absorbs the recovery that follows the final rep" do
      expect(result[:phases].map { |phase| phase[:kind] }).not_to include("easier")
    end
  end

  # The reference is the median of every lap pace, and on an interval session the
  # paces are bimodal with roughly equal counts either side — so the median lands
  # inside the recovery cluster and every recovery classifies as steady rather
  # than easier. Requiring an easier phase between reps meant a set only
  # collapsed when the recoveries were slower than the warmup, which is to say
  # walked. A runner who jogs them got a dozen loose phases and no repeats.
  describe "recoveries at any pace" do
    [ 270, 300, 330, 360, 390, 420 ].each do |recovery_pace|
      it "collapses a set whose recoveries were run at #{recovery_pace}s/km" do
        laps = [ lap(1_000, 360), lap(1_000, 360) ] +
               reps(6, distance: 1_000, pace: 240, recovery_pace: recovery_pace) +
               [ lap(1_000, 380), lap(1_000, 380) ]

        expect(described_class.call(laps)[:phases].map { |phase| phase[:kind] })
          .to eq(%w[warmup repeats cooldown])
      end
    end
  end

  describe "an alternation too small to cross the threshold" do
    # Cruise intervals: 5 x 1 km at 3:45 alternating with 1 km floats at 4:05.
    # The median sits between the two, and neither clears the band from it.
    let(:laps) { Array.new(5) { [ lap(1_000, 225), lap(1_000, 245) ] }.flatten }

    it "still reads as continuous, because no lap separates out" do
      expect(result[:shape]).to eq("continuous")
    end

    # Saying "the laps hold one pace throughout" about a run that alternated by
    # 20s per kilometre is a confident false statement, which is worse than
    # saying nothing.
    it "does not claim one pace throughout" do
      expect(result[:explanation]).not_to match(/one pace throughout/)
      expect(result[:explanation]).to match(/range over 20 seconds per kilometre/)
    end

    it "reports the range so a client can see it" do
      expect(result[:phases].sole[:pace_spread_seconds]).to eq(20.0)
    end
  end

  describe "heart rate across a phase" do
    # Duration-weighted. An unweighted mean lets a 200 m float count for as much
    # as the kilometre beside it — worth ten beats a minute on a warmup.
    it "weights by duration rather than by lap" do
      laps = [ lap(1_000, 400, heart_rate: 120), lap(200, 400, heart_rate: 150),
               lap(1_000, 300, heart_rate: 165), lap(1_000, 300, heart_rate: 168) ]

      warmup = described_class.call(laps).dig(:phases, 0)
      expect(warmup[:average_heart_rate]).to eq(125)
    end

    it "excludes laps carrying no reading, and says how many carried one" do
      laps = [ lap(1_000, 360, heart_rate: 140), lap(1_000, 360, heart_rate: nil),
               lap(1_000, 360, heart_rate: 150), lap(400, 355, heart_rate: nil) ]

      phase = described_class.call(laps)[:phases].sole
      expect(phase[:average_heart_rate]).to eq(145)
      expect(phase[:heart_rate_from_laps]).to eq(2)
    end

    it "stays quiet about the count when every lap carried a reading" do
      laps = [ lap(1_000, 360), lap(1_000, 360), lap(1_000, 360), lap(400, 355) ]

      expect(described_class.call(laps)[:phases].sole).not_to have_key(:heart_rate_from_laps)
    end
  end

  # When a set fades far enough its last efforts drift back inside the tolerance
  # band, stop classifying as reps, and merge with the recoveries around them
  # into one long steady phase. Absorbing that as the set's trailing recovery
  # reported a twelve-minute recovery among sixty-second ones.
  describe "a set that fades out of its own band" do
    let(:laps) do
      [ lap(1_000, 360), lap(1_000, 360) ] +
        [ 262, 266, 271, 279, 288, 294 ].flat_map { |pace| [ lap(1_000, pace), lap(200, 300) ] } +
        [ lap(1_400, 375) ]
    end

    it "keeps the efforts it can still recognise as a set" do
      repeats = result[:phases].find { |phase| phase[:kind] == "repeats" }

      expect(repeats[:reps]).to eq(4)
      expect(repeats[:rep_paces_per_km]).to eq([ 262.0, 266.0, 271.0, 279.0 ])
    end

    it "does not swallow the fade as though it were a recovery" do
      repeats = result[:phases].find { |phase| phase[:kind] == "repeats" }

      expect(repeats[:recovery_seconds]).to eq(60)
      expect(repeats).not_to have_key(:recovery_seconds_range)
    end

    it "reports what is left of the set as running in its own right" do
      expect(result[:phases].map { |phase| phase[:kind] }).to eq(%w[warmup repeats steady easier])
    end
  end

  describe "uneven recoveries" do
    # A median of 86 seconds says nothing about the one that ran to four minutes,
    # and the field name implies a single fact.
    it "reports the range when the median would be hiding one" do
      laps = [ lap(1_000, 360) ] +
             [ lap(1_000, 240), lap(200, 430),
               lap(1_000, 240), lap(550, 430),
               lap(1_000, 240), lap(200, 430),
               lap(1_000, 240) ] +
             [ lap(1_000, 380) ]

      repeats = described_class.call(laps)[:phases].find { |phase| phase[:kind] == "repeats" }
      expect(repeats[:recovery_seconds]).to eq(86)
      expect(repeats[:recovery_seconds_range]).to eq([ 86, 237 ])
    end

    it "stays quiet when they were all much the same" do
      laps = [ lap(1_000, 360) ] + reps(4, distance: 1_000, pace: 240) + [ lap(1_000, 380) ]

      repeats = described_class.call(laps)[:phases].find { |phase| phase[:kind] == "repeats" }
      expect(repeats).not_to have_key(:recovery_seconds_range)
    end
  end

  # The set is judged as it is walked, not after. Judged whole, the one window
  # that held the six kilometre reps also held the strides after them and failed
  # the length check, so a common session shape reported no repeats at all.
  describe "a set followed by something shorter" do
    let(:laps) do
      [ lap(1_000, 360), lap(1_000, 360) ] +
        reps(6, distance: 1_000, pace: 240, recovery_distance: 400, recovery_pace: 360) +
        reps(2, distance: 200, pace: 210, recovery_distance: 200, recovery_pace: 400) +
        [ lap(1_000, 360) ]
    end

    it "still finds the set" do
      repeats = result[:phases].find { |phase| phase[:kind] == "repeats" }

      expect(repeats).to include(reps: 6, rep_distance_km: 1.0)
    end

    it "leaves the strides as the loose efforts they are" do
      kinds = result[:phases].map { |phase| phase[:kind] }

      expect(kinds.first(2)).to eq(%w[warmup repeats])
      expect(kinds.count("faster")).to eq(2)
      expect(kinds).not_to include("cooldown")
    end

    # The jog between the last rep and the first stride is the run-in to the
    # strides as much as it is the set's recovery, so the set ends on its rep.
    it "does not swallow the run-in to the strides as the set's last recovery" do
      repeats = result[:phases].find { |phase| phase[:kind] == "repeats" }

      expect(repeats[:distance_km]).to eq(8.0)
      expect(result[:phases][2][:kind]).to be_in(%w[steady easier])
    end
  end

  # Strides before the main work are as common as strides after it. Ranked on
  # count, four strides beat three 1600s and the session reads as a set of
  # strides with 4.8 km of unexplained fast running beside it.
  describe "strides before the main set" do
    let(:laps) do
      [ lap(2_000, 330) ] +
        reps(4, distance: 200, pace: 210, recovery_distance: 200, recovery_pace: 400) +
        reps(3, distance: 1_600, pace: 240, recovery_distance: 400, recovery_pace: 360) +
        [ lap(1_000, 330) ]
    end

    it "reports the main set as the repeats" do
      repeats = result[:phases].find { |phase| phase[:kind] == "repeats" }

      expect(repeats).to include(reps: 3, rep_distance_km: 1.6)
    end
  end

  describe "a ladder" do
    def ladder(first, second)
      [ lap(2_000, 330) ] +
        reps(4, distance: first, pace: 240, recovery_distance: 400, recovery_pace: 360) +
        reps(4, distance: second, pace: 225, recovery_distance: 400, recovery_pace: 360) +
        [ lap(1_000, 330) ]
    end

    it "collapses the set carrying the most distance when it comes first" do
      repeats = described_class.call(ladder(1_000, 400))[:phases].find { |phase| phase[:kind] == "repeats" }

      expect(repeats).to include(reps: 4, rep_distance_km: 1.0)
    end

    it "collapses the set carrying the most distance when it comes last" do
      repeats = described_class.call(ladder(400, 1_000))[:phases].find { |phase| phase[:kind] == "repeats" }

      expect(repeats).to include(reps: 4, rep_distance_km: 1.0)
    end

    # Distance, not count: three kilometre reps are the session and five 400s
    # beside them are not, however the two are ordered.
    it "prefers the set with more distance over the set with more reps" do
      laps = [ lap(2_000, 330) ] +
             reps(3, distance: 1_000, pace: 240, recovery_distance: 400, recovery_pace: 360) +
             reps(5, distance: 400, pace: 225, recovery_distance: 400, recovery_pace: 360) +
             [ lap(1_000, 330) ]

      repeats = described_class.call(laps)[:phases].find { |phase| phase[:kind] == "repeats" }
      expect(repeats).to include(reps: 3, rep_distance_km: 1.0)
    end

    it "breaks a tie on distance by the number of reps" do
      laps = [ lap(2_000, 330) ] +
             reps(3, distance: 1_000, pace: 240, recovery_distance: 400, recovery_pace: 360) +
             reps(6, distance: 500, pace: 230, recovery_distance: 400, recovery_pace: 360) +
             [ lap(1_000, 330) ]

      repeats = described_class.call(laps)[:phases].find { |phase| phase[:kind] == "repeats" }
      expect(repeats).to include(reps: 6, rep_distance_km: 0.5)
    end
  end

  # Reps admitted under the length ratio can differ by forty percent, and a
  # median over an apex of 1200, 1600 and 1200 says 1.2 km about a set a third
  # of which was longer.
  describe "a pyramid built on adding steps" do
    let(:laps) do
      [ lap(2_000, 330) ] +
        [ 400, 800, 1_200, 1_600, 1_200, 800, 400 ].flat_map { |metres| [ lap(metres, 215), lap(400, 360) ] } +
        [ lap(1_000, 330) ]
    end

    it "collapses the apex and reports the range of rep distances" do
      repeats = result[:phases].find { |phase| phase[:kind] == "repeats" }

      expect(repeats).to include(reps: 3, rep_distance_km: 1.2, rep_distance_range_km: [ 1.2, 1.6 ])
    end

    it "stays quiet about the range when the reps were the same length" do
      laps = [ lap(1_000, 360) ] + reps(4, distance: 1_000, pace: 240) + [ lap(1_000, 380) ]

      repeats = described_class.call(laps)[:phases].find { |phase| phase[:kind] == "repeats" }
      expect(repeats).not_to have_key(:rep_distance_range_km)
    end
  end

  # A missed lap press reads two reps as one long one, which ends the set at
  # the length check. Four reps of an eight-rep session is a confident figure
  # unless the phase says the alternation went on.
  describe "a set the length check cut short" do
    let(:laps) do
      [ lap(1_000, 360) ] +
        reps(4, distance: 1_000, pace: 240, recovery_distance: 400, recovery_pace: 360) +
        [ lap(2_000, 240), lap(400, 360) ] +
        reps(2, distance: 1_000, pace: 240, recovery_distance: 400, recovery_pace: 360) +
        [ lap(1_000, 380) ]
    end

    it "says the alternation continued past the set it found" do
      repeats = result[:phases].find { |phase| phase[:kind] == "repeats" }

      expect(repeats[:reps]).to eq(4)
      expect(repeats[:note]).to match(/continued past this set/)
    end

    it "carries no note when the set ran to the end of the alternation" do
      laps = [ lap(1_000, 360) ] + reps(4, distance: 1_000, pace: 240) + [ lap(1_000, 380) ]

      repeats = described_class.call(laps)[:phases].find { |phase| phase[:kind] == "repeats" }
      expect(repeats).not_to have_key(:note)
    end
  end

  describe "what does not count as repeats" do
    context "with only two fast efforts" do
      let(:laps) { [ lap(1_000, 360) ] + reps(2, distance: 1_000, pace: 270) + [ lap(1_000, 360) ] }

      it "leaves them as their own phases" do
        expect(result[:phases].map { |phase| phase[:kind] }).to include("faster")
        expect(result[:phases].map { |phase| phase[:kind] }).not_to include("repeats")
      end
    end

    context "with fast efforts of unrelated lengths" do
      let(:laps) do
        [ lap(1_000, 360),
          lap(400, 270), lap(200, 420),
          lap(1_600, 270), lap(200, 420),
          lap(3_000, 270), lap(1_000, 360) ]
      end

      it "declines to call them a set" do
        expect(result[:phases].map { |phase| phase[:kind] }).not_to include("repeats")
      end
    end
  end

  describe "a progression run" do
    let(:laps) { [ lap(1_000, 400), lap(1_000, 398), lap(1_000, 360), lap(1_000, 300), lap(1_000, 298) ] }

    it "reads as phases from easier through to faster" do
      expect(result[:phases].map { |phase| phase[:kind] }).to eq(%w[easier steady faster])
    end

    it "weights pace by distance within a phase" do
      expect(result[:phases].first[:pace_per_km]).to eq(399.0)
    end
  end

  describe "the tolerance band" do
    # Six percent of a slow pace is a wider window than six percent of a fast
    # one, which is the point: ordinary variation scales with the pace.
    it "does not split an easy run on variation a fast run would flag" do
      easy = described_class.call([ lap(1_000, 400), lap(1_000, 420), lap(1_000, 410) ])

      expect(easy[:shape]).to eq("continuous")
    end

    it "still splits when the difference clears both tolerances" do
      mixed = described_class.call([ lap(1_000, 400), lap(1_000, 340), lap(1_000, 400) ])

      expect(mixed[:phases].map { |phase| phase[:kind] }).to eq(%w[steady faster steady])
    end
  end

  describe ".uniform_lap_distance" do
    it "recognises a watch that was lapping automatically" do
      laps = [ lap(1_000, 360), lap(1_000, 355), lap(1_000, 365), lap(340, 350) ]

      expect(described_class.uniform_lap_distance(laps)).to eq(1.0)
    end

    it "returns nothing where the laps were pressed by hand" do
      laps = [ lap(1_000, 360), lap(400, 270), lap(200, 420), lap(1_600, 300) ]

      expect(described_class.uniform_lap_distance(laps)).to be_nil
    end

    it "returns nothing where the final lap is a full one, which no auto-lap produces" do
      laps = [ lap(1_000, 360), lap(1_000, 360), lap(1_000, 360), lap(1_000, 360), lap(1_000, 360) ]

      expect(described_class.uniform_lap_distance(laps)).to be_nil
    end

    # Without a roundness check, five hand-pressed 1200 m blocks read as a
    # 1.2 km auto-lap and the response asserts something false about the watch.
    it "returns nothing for equal laps at a distance no watch laps at" do
      laps = Array.new(5) { lap(1_200, 300) } + [ lap(400, 350) ]

      expect(described_class.uniform_lap_distance(laps)).to be_nil
    end

    it "recognises a watch lapping every mile" do
      laps = Array.new(4) { lap(1_609, 340) } + [ lap(600, 345) ]

      expect(described_class.uniform_lap_distance(laps)).to eq(1.61)
    end

    # Two matching laps are a coincidence. Three are a setting.
    it "declines to call it a setting on two full laps" do
      laps = [ lap(1_000, 360), lap(1_000, 360), lap(300, 355) ]

      expect(described_class.uniform_lap_distance(laps)).to be_nil
    end
  end
end
