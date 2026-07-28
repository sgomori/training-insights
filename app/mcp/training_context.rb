# The runner's load state as of today, computed once per call and attached to
# every tool response that needs it.
#
# Two problems drove this out of the individual tools. Consistency: the
# acute:chronic ratio has to mean the same thing everywhere, so it is fixed at a
# trailing 7 days against a 28-day chronic baseline regardless of the window a
# caller asked about. Asking for a 90-day summary should not change what the
# runner's current load is.
#
# And interpretability: a number is not readable without knowing what preceded
# it. A flat, laboured run on the ninth consecutive training day is a different
# fact than the same run after a rest week, and the client cannot tell those
# apart from the activity alone. This block supplies what preceded it.
#
# It carries no verdict. It reports load state and lets the client draw the line.
class TrainingContext
  ACUTE_DAYS = 7
  CHRONIC_DAYS = 28

  # A training-day streak is counted back this far and no further. Anything
  # longer is a data question rather than a training one, and is reported as
  # having reached the limit rather than silently truncated.
  STREAK_LOOKBACK_DAYS = 60

  attr_reader :zone, :today

  def self.current(zone: nil)
    new(zone: zone || Runner.current_time_zone)
  end

  def initialize(zone:)
    @zone = zone
    @today = zone.today
  end

  def to_h
    {
      as_of: today.to_s,
      timezone: zone.name,
      acute_7d_tss: acute_tss.round(1),
      chronic_weekly_tss: chronic_weekly_tss&.round(1),
      acute_chronic_ratio: MetricInterpretation.describe(
        :acute_chronic_ratio, value: acute_chronic_ratio, caveats: ratio_caveats.presence || []
      ),
      consecutive_training_days: consecutive_training_days,
      days_since_last_activity: days_since_last_activity,
      rest_days_in_last_7: rest_days_in_last_7,
      history_spans_days: history_spans_days,
      sufficient_history_for_chronic_load: sufficient_history_for_chronic_load?,
      next_race: next_race
    }.compact
  end

  # Trailing 7 calendar days including today.
  def acute_tss
    @acute_tss ||= tss_since(today - (ACUTE_DAYS - 1))
  end

  # The 28-day total normalised to a weekly figure, so a steady block sits near
  # 1.0. Dividing a 7-day sum by a 28-day sum would report roughly 0.25 instead.
  def chronic_weekly_tss
    return @chronic_weekly_tss if defined?(@chronic_weekly_tss)

    total = tss_since(today - (CHRONIC_DAYS - 1))
    @chronic_weekly_tss = total.zero? ? nil : total / (CHRONIC_DAYS / 7.0)
  end

  def acute_chronic_ratio
    return nil if chronic_weekly_tss.nil? || chronic_weekly_tss.zero?

    (acute_tss / chronic_weekly_tss).round(2)
  end

  # Consecutive calendar days with at least one activity, counting back from the
  # most recent training day. Read it together with days_since_last_activity: a
  # streak of 9 that ended three days ago is not nine days of accumulated load.
  def consecutive_training_days
    dates = training_dates
    return 0 if dates.empty?

    streak = 1
    dates.each_cons(2) do |later, earlier|
      break unless earlier == later - 1

      streak += 1
    end
    streak
  end

  def days_since_last_activity
    dates = training_dates
    return nil if dates.empty?

    (today - dates.first).to_i
  end

  def rest_days_in_last_7
    trained = training_dates.count { |d| d > today - ACUTE_DAYS }
    ACUTE_DAYS - trained
  end

  # A 28-day window is only a chronic load if 28 days of training sit behind it.
  # Asking for a long period does not manufacture history.
  def sufficient_history_for_chronic_load?
    history_spans_days >= CHRONIC_DAYS
  end

  def history_spans_days
    return @history_spans_days if defined?(@history_spans_days)

    earliest = Activity.minimum(:started_at)
    @history_spans_days = earliest.nil? ? 0 : (today - earliest.in_time_zone(zone).to_date).to_i + 1
  end

  private

  def ratio_caveats
    caveats = []
    unless sufficient_history_for_chronic_load?
      caveats << "Only #{history_spans_days} #{'day'.pluralize(history_spans_days)} of history exist, " \
                 "so the chronic baseline is not yet a true chronic load."
    end
    if activities_missing_tss.positive?
      caveats << "#{activities_missing_tss} #{'activity'.pluralize(activities_missing_tss)} in the last " \
                 "#{CHRONIC_DAYS} days #{activities_missing_tss == 1 ? 'has' : 'have'} no TSS, so load is understated."
    end
    caveats
  end

  def activities_missing_tss
    @activities_missing_tss ||= chronic_window.count { |_started_at, tss| tss.nil? }
  end

  def tss_since(first_day)
    cutoff = zone.parse(first_day.to_s).beginning_of_day
    chronic_window.sum { |started_at, tss| started_at >= cutoff ? tss.to_f : 0.0 }
  end

  # One query serves both load windows: the acute window is a subset of the
  # chronic one, so there is no reason to hit the database twice.
  def chronic_window
    @chronic_window ||= Activity
      .starting_between(zone.parse((today - (CHRONIC_DAYS - 1)).to_s).beginning_of_day, zone.parse(today.to_s).end_of_day)
      .pluck(:started_at, :tss_score)
  end

  # Distinct training days, most recent first, over the streak lookback.
  def training_dates
    @training_dates ||= Activity
      .starting_between(zone.parse((today - STREAK_LOOKBACK_DAYS).to_s).beginning_of_day, zone.parse(today.to_s).end_of_day)
      .pluck(:started_at)
      .map { |t| t.in_time_zone(zone).to_date }
      .uniq
      .sort
      .reverse
  end

  def next_race
    race = Race.next_race
    return nil if race.nil?

    {
      name: race.name,
      date: race.race_date.to_s,
      days_until: race.days_until,
      distance_km: (race.distance_meters / 1000.0).round(1)
    }
  end
end
