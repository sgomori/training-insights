# A resolved span of calendar days, and every aggregation the tools take over it.
#
# Nine tools ask the same questions of a date range: how much was run, how hilly
# it was, how much load it carried, how the intensity was distributed, what the
# aerobic signals looked like. Before this object each tool grew its own copy of
# those aggregations, and the copies drifted — exactly the way the acute:chronic
# ratio drifted before TrainingContext pulled it into one place.
#
# The rules below are load-bearing and belong here rather than in any one tool:
#
# - Boundaries are calendar days in the runner's timezone, never rolling
#   instants. A run at 23:00 local counts on the day the runner ran it.
# - Nils are excluded from aggregates, never coerced to zero. The pipeline emits
#   null when a stream was missing, and a missing metric is not a zero one.
# - Zone percentages are weighted by duration before being combined.
# - Races count fully toward volume, terrain and load, and are excluded from the
#   aerobic averages, with the basis stating the exclusion.
# - Every average reports the sample size that produced it.
#
# The window shapes response fragments but takes no view on what they mean.
# Reading guidance comes from MetricInterpretation; verdicts belong to the client.
class TrainingWindow
  include MetricMath

  # Below this many contributing activities, trends and averages are noise.
  MIN_SAMPLE_FOR_TREND = 3

  # Pace variability above this indicates intervals or varied terrain rather
  # than a steady effort. Metrics that assume even pacing are not meaningful
  # past it — see the cardiac drift signal below.
  STEADY_STATE_PACE_CV_MAX = 0.20

  attr_reader :from, :to, :zone

  class << self
    # The `days` calendar days ending on `last_day`, inclusive of both ends.
    def ending(last_day, days:, zone: nil)
      zone ||= Runner.current_time_zone
      new(from: last_day - (days - 1), to: last_day, zone: zone)
    end

    def between(from, to, zone: nil)
      new(from: from, to: to, zone: zone || Runner.current_time_zone)
    end
  end

  def initialize(from:, to:, zone:)
    @zone = zone
    @from = from.to_date
    @to = to.to_date
  end

  def days
    (to - from).to_i + 1
  end

  def weeks
    days / 7.0
  end

  def empty?
    activities.empty?
  end

  # Materialised once, with the race association preloaded: every section below
  # walks the same set, so loading it per section would re-query for each.
  def activities
    @activities ||= Activity
      .starting_between(zone.parse(from.to_s).beginning_of_day, zone.parse(to.to_s).end_of_day)
      .includes(:race)
      .chronological
      .to_a
  end

  def training_only
    @training_only ||= activities.reject(&:race?)
  end

  def races
    @races ||= activities.select(&:race?)
  end

  # Self-describing period metadata, so a response carrying window figures also
  # carries what window they were taken over.
  def period
    {
      days: days,
      from: from.to_s,
      to: to.to_s,
      timezone: zone.name,
      activity_count: activities.size
    }
  end

  def overlaps?(other)
    from <= other.to && other.from <= to
  end

  def volume
    distances = activities.filter_map(&:distance_meters)
    durations = activities.filter_map(&:duration_seconds)

    {
      activity_count: activities.size,
      total_distance_km: (distances.sum / 1000.0).round(1),
      total_duration_hours: (durations.sum / 3600.0).round(1),
      average_distance_km: distances.empty? ? nil : (distances.sum / distances.size / 1000.0).round(1),
      longest_run_km: distances.empty? ? nil : (distances.max / 1000.0).round(1),
      days_with_activity: activity_dates.size
    }
  end

  # Terrain is reported separately from volume because it qualifies every pace
  # figure alongside it. The same 10k is a different effort on a hill, and the
  # client has no way to know which it was looking at otherwise.
  #
  # The ratio is taken over activities carrying both figures, so a run with no
  # altitude data cannot drag the average toward flat.
  def terrain
    measured = elevation_measured
    gain = measured.sum(&:elevation_gain_meters)

    {
      total_elevation_gain_m: gain.round,
      elevation_gain_per_km: MetricInterpretation.describe(
        :elevation_gain_per_km, value: gain_per_km, sample_size: measured.size
      )
    }
  end

  def gain_per_km
    measured = elevation_measured
    distance_km = measured.sum(&:distance_meters) / 1000.0
    return nil unless distance_km.positive?

    (measured.sum(&:elevation_gain_meters) / distance_km).round(1)
  end

  # How much the terrain cost, in seconds per kilometre: the gap between raw
  # pace and its flat-equivalent, over activities carrying both.
  def terrain_cost_seconds_per_km
    measured = activities.select { |a| a.average_pace_per_km && a.avg_grade_adjusted_pace_per_km }
    return nil if measured.empty?

    raw = measured.sum(&:average_pace_per_km) / measured.size
    adjusted = measured.sum(&:avg_grade_adjusted_pace_per_km) / measured.size
    (raw - adjusted).round(1)
  end

  # Load scoped to this window. The acute:chronic ratio is deliberately absent:
  # it belongs to the runner's present state, not to an arbitrary window, and
  # lives in TrainingContext so that asking for a 90-day summary cannot change
  # what the ratio says.
  def load
    {
      total_tss: total_tss.round(1),
      average_daily_tss: (total_tss / days).round(1),
      average_weekly_tss: (total_tss / weeks).round(1),
      # Load is understated by exactly this many activities, because the
      # pipeline could not derive a TSS for them.
      activities_missing_tss: activities.count { |a| a.tss_score.nil? }
    }
  end

  def total_tss
    @total_tss ||= activities.filter_map(&:tss_score).sum
  end

  def total_distance_meters
    @total_distance_meters ||= activities.filter_map(&:distance_meters).sum
  end

  def intensity_distribution
    {
      basis: "duration_weighted",
      hr_zones_pct: zones(:hr_zone_distribution),
      pace_zones_pct: zones(:pace_zone_distribution)
    }
  end

  # Zone percentages are per-activity and must be weighted by duration before
  # they can be combined. Averaging the percentages would count a 20-minute
  # recovery jog equally with a 3-hour long run.
  def zones(column)
    contributing = activities.select { |a| a.public_send(column).present? && a.duration_seconds.to_f.positive? }
    return { zones: nil, activities_contributing: 0 } if contributing.empty?

    total_duration = contributing.sum(&:duration_seconds)
    totals = Hash.new(0.0)

    contributing.each do |activity|
      activity.public_send(column).each do |zone_name, pct|
        totals[zone_name] += pct.to_f * activity.duration_seconds
      end
    end

    {
      zones: totals.transform_values { |v| (v / total_duration).round(1) },
      activities_contributing: contributing.size,
      hours_contributing: (total_duration / 3600.0).round(1)
    }
  end

  # Every signal ships with the shared reading guidance from
  # MetricInterpretation, so the client is never handed a bare number it has no
  # way to scale.
  #
  # Pace and efficiency factor appear twice: once raw, once grade-adjusted. The
  # pipeline normalises both against the altitude stream, and the adjusted
  # figure is the one that survives a change of route.
  #
  # Races are excluded here and nowhere else. A race is real load and real
  # volume, so it counts fully in those sections, but it is a maximal effort and
  # its aerobic figures are not comparable with a training run's. It would not be
  # caught by the steady-state filter either: a well-executed race is evenly
  # paced, so it passes the pace variability guard while distorting every average
  # it enters.
  def aerobic_signals
    {
      basis: aerobic_basis,
      aerobic_decoupling_pct: describe_mean(:aerobic_decoupling_pct),
      efficiency_factor: describe_mean(:efficiency_factor, precision: 3),
      grade_adjusted_efficiency_factor: describe_mean(:grade_adjusted_efficiency_factor, precision: 3),
      average_pace_per_km: describe_mean(:average_pace_per_km, precision: 1),
      avg_grade_adjusted_pace_per_km: describe_mean(:avg_grade_adjusted_pace_per_km, precision: 1),
      pace_variability: describe_mean(:pace_cv, precision: 3),
      cardiac_drift_bpm: cardiac_drift
    }
  end

  # Mean of a column with the sample size behind it. Training efforts only by
  # default, matching the aerobic-signal rule; pass `scope: :all` for the
  # sections where a race is real work.
  def mean(column, precision: 2, scope: :training)
    source = scope == :all ? activities : training_only
    mean_with_sample(source.map(&column), precision: precision)
  end

  def describe_mean(column, as: nil, precision: 2, scope: :training)
    MetricInterpretation.describe(as || column, **mean(column, precision: precision, scope: scope))
  end

  # Distinct calendar days carrying at least one activity, in the window's zone.
  def activity_dates
    @activity_dates ||= activities.map { |a| local_date(a) }.uniq
  end

  def local_date(activity)
    activity.started_at.in_time_zone(zone).to_date
  end

  # The ISO weeks the window touches, chronologically. Weeks are not clipped to
  # the window: a window that starts mid-week reports its first bucket as
  # incomplete rather than silently under-counting it, because a partial week's
  # volume is not comparable with a full one's.
  def weekly_buckets
    @weekly_buckets ||= begin
      by_week = activities.group_by { |a| local_date(a).beginning_of_week }

      week_starts(from.beginning_of_week, to.beginning_of_week).map do |week_start|
        WeeklyBucket.new(
          week_start: week_start,
          window_from: from,
          window_to: to,
          activities: by_week.fetch(week_start, []),
          zone: zone
        )
      end
    end
  end

  # One ISO week of the window, and the roll-ups the load tools take per week.
  class WeeklyBucket
    attr_reader :week_start, :activities

    def initialize(week_start:, window_from:, window_to:, activities:, zone:)
      @week_start = week_start
      @window_from = window_from
      @window_to = window_to
      @activities = activities
      @zone = zone
    end

    def week_end
      week_start + 6
    end

    # The part of the week that falls inside the window. A bucket is only
    # comparable with its neighbours when this covers all seven days.
    def days_in_window
      (last_day_in_window - first_day_in_window).to_i + 1
    end

    def complete?
      days_in_window == 7
    end

    def activity_count
      activities.size
    end

    def distance_km
      (activities.filter_map(&:distance_meters).sum / 1000.0).round(1)
    end

    def longest_run_km
      distances = activities.filter_map(&:distance_meters)
      return nil if distances.empty?

      (distances.max / 1000.0).round(1)
    end

    def tss
      activities.filter_map(&:tss_score).sum.round(1)
    end

    def activities_missing_tss
      activities.count { |a| a.tss_score.nil? }
    end

    # Load per calendar day across the in-window part of the week, rest days
    # included as zero.
    #
    # This inverts the project-wide rule that a missing value is never a zero,
    # and the inversion is deliberate: a day with no run genuinely carries no
    # load, which is a different fact from an activity whose tss_score is nil
    # because a stream was missing. Foster's monotony is defined over the days
    # of the week, so the rest days have to be present as zeros or the standard
    # deviation is taken over the wrong population.
    def daily_tss
      totals = Hash.new(0.0)
      activities.each do |activity|
        totals[activity.started_at.in_time_zone(@zone).to_date] += activity.tss_score.to_f
      end

      (first_day_in_window..last_day_in_window).map { |date| totals[date] }
    end

    def to_h
      {
        week_start: week_start.to_s,
        week_end: week_end.to_s,
        activity_count: activity_count,
        distance_km: distance_km,
        longest_run_km: longest_run_km,
        tss: tss,
        complete_week: complete?,
        days_in_window: days_in_window
      }
    end

    private

    def first_day_in_window
      [ week_start, @window_from ].max
    end

    def last_day_in_window
      [ week_end, @window_to ].min
    end
  end

  private

  def week_starts(first, last)
    starts = []
    week = first
    while week <= last
      starts << week
      week += 7
    end
    starts
  end

  def elevation_measured
    @elevation_measured ||= activities.select { |a| a.elevation_gain_meters && a.distance_meters.to_f.positive? }
  end

  def aerobic_basis
    return "All activities in the period." if races.empty?

    "Training efforts only. #{races.size} race #{'effort'.pluralize(races.size)} excluded, " \
      "because a maximal effort is not comparable with a training run."
  end

  # Cardiac drift assumes an even effort — on an interval session the figure is
  # arithmetically correct and analytically meaningless. Rather than averaging
  # everything and appending a warning, the average is taken over steady-state
  # efforts only and the response says what was set aside.
  def cardiac_drift
    measured = training_only.select(&:cardiac_drift_bpm)
    steady = measured.select { |a| a.pace_cv && a.pace_cv <= STEADY_STATE_PACE_CV_MAX }
    variable = measured.count { |a| a.pace_cv && a.pace_cv > STEADY_STATE_PACE_CV_MAX }
    unclassified = measured.count { |a| a.pace_cv.nil? }

    caveats = [ "Averaged over steady-state efforts only." ]
    if variable.positive?
      caveats << "#{variable} #{'activity'.pluralize(variable)} excluded as non-steady-state " \
                 "(pace variability above #{STEADY_STATE_PACE_CV_MAX})."
    end
    if unclassified.positive?
      caveats << "#{unclassified} excluded because pace variability could not be derived."
    end

    MetricInterpretation.describe(
      :cardiac_drift_bpm,
      **mean_with_sample(steady.map(&:cardiac_drift_bpm), precision: 1),
      caveats: caveats
    )
  end
end
