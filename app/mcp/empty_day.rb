# What surrounds a day that holds no activity.
#
# An empty day is most often a wrong year. A client that does not know today's
# date fills one in from habit and asks about a day a year off, and a bare
# "nothing on that day" gives it no way to notice. So the miss carries the
# anchors that expose it: today, the latest activity, the neighbours of the
# requested day with the gaps to them, and the same day in the adjacent and
# current years. Data first and prose second, so a client can re-call from
# either.
class EmptyDay
  def initialize(date, zone)
    @date = date
    @zone = zone
    @today = zone.today
  end

  def to_h
    {
      as_of: @today.to_s,
      most_recent_activity: latest && brief(latest),
      nearest_before: before && brief(before).merge(days_before: (@date - day_of(before)).to_i),
      nearest_after: after && brief(after).merge(days_after: (day_of(after) - @date).to_i),
      same_day_other_years: same_day_other_years.map { |activity| brief(activity) }.presence
    }.compact
  end

  def to_prose
    [ anchor_sentence, neighbours_sentence, other_years_sentence ].compact.join(" ")
  end

  private

  def latest
    return @latest if defined?(@latest)

    @latest = Activity.most_recent_first.first
  end

  # A neighbour that is also the latest activity has been named already, so it
  # is dropped rather than read out twice.
  def before
    return @before if defined?(@before)

    found = Activity.where(started_at: ...@zone.parse(@date.to_s).beginning_of_day).most_recent_first.first
    @before = found == latest ? nil : found
  end

  def after
    return @after if defined?(@after)

    found = Activity.where(started_at: @zone.parse(@date.to_s).end_of_day..).chronological.first
    @after = found == latest ? nil : found
  end

  # The years either side of the requested one, and the current year, are the
  # candidates that expose a wrong year. Every year of history would bury it.
  def same_day_other_years
    @same_day_other_years ||= [ @date.year - 1, @date.year + 1, @today.year ].uniq.sort.filter_map do |year|
      next if year == @date.year || !Date.valid_date?(year, @date.month, @date.day)

      Activity.on_day(Date.new(year, @date.month, @date.day), @zone).chronological.max_by { |activity| activity.distance_meters.to_f }
    end
  end

  def anchor_sentence
    return "Today is #{@today}." if latest.nil?

    "Today is #{@today} and the most recent activity was on #{describe(latest)}."
  end

  def neighbours_sentence
    parts = []
    parts << "#{days((@date - day_of(before)).to_i)} before, on #{describe(before)}" if before
    parts << "#{days((day_of(after) - @date).to_i)} after, on #{describe(after)}" if after
    return nil if parts.empty?

    if parts.one?
      "The nearest activity was #{parts.first}."
    else
      "The nearest activities were #{parts.join(' and ')}."
    end
  end

  def other_years_sentence
    named = same_day_other_years.map { |activity| describe(activity) }
    return nil if named.empty?

    if named.one?
      "The same day in another year holds an activity: #{named.first}."
    else
      "The same day in other years holds activities: #{named.join(', ')}."
    end
  end

  def brief(activity)
    { date: day_of(activity).to_s, distance_km: km(activity), activity_type: activity.activity_type }.compact
  end

  def describe(activity)
    detail = [ ("#{km(activity)} km" if km(activity)), activity.activity_type ].compact
    "#{day_of(activity)} (#{detail.join(', ')})"
  end

  def day_of(activity)
    activity.started_at.in_time_zone(@zone).to_date
  end

  def km(activity)
    activity.distance_meters.nil? ? nil : (activity.distance_meters / 1000.0).round(1)
  end

  def days(count)
    "#{count} #{'day'.pluralize(count)}"
  end
end
