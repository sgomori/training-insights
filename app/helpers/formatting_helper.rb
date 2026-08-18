# How a metric is written on the page.
#
# The wire carries seconds per kilometre and metres, because those are the
# honest machine representations and what every tool returns. Nobody reads them
# that way, so the conversion happens here — the same split the chat prompt makes
# when it tells the model to write 4:52/km rather than 292.
#
# Every method takes a nil, because most computed metrics are nullable by design
# and a view that has to check first would check inconsistently.
module FormattingHelper
  # Seconds per kilometre as m:ss/km.
  def pace(seconds_per_km)
    return nil if seconds_per_km.nil?

    total = seconds_per_km.round
    format("%d:%02d/km", total / 60, total % 60)
  end

  # Metres as kilometres, to one decimal place. Whole numbers keep their zero so
  # a column of distances stays aligned.
  def distance(meters)
    return nil if meters.nil?

    "#{format('%.1f', meters / 1000.0)} km"
  end

  # Seconds as h:mm:ss, or m:ss under an hour. Race results are the caller here,
  # and a 41-minute 10k reads worse as 0:41:12.
  def elapsed(seconds)
    return nil if seconds.nil?

    total = seconds.round
    hours = total / 3600
    return format("%d:%02d:%02d", hours, (total % 3600) / 60, total % 60) if hours.positive?

    format("%d:%02d", total / 60, total % 60)
  end

  # The compact form the sidebar uses. The year is dropped for the current one,
  # where it is noise, and kept for any other, where its absence would be a lie.
  #
  # "Current" is the runner's year, not the server's. Date.current is UTC here,
  # so on a December evening in Toronto it has already rolled over: that night's
  # run would print its year while the next morning's race printed none.
  def short_date(date)
    return nil if date.nil?

    date.year == Runner.current_time_zone.today.year ? date.strftime("%b %-d") : date.strftime("%b %-d, %Y")
  end

  # Whole days between a date and the runner's today, written the way a status
  # line writes it. Same reason short_date reaches for the runner's zone: the
  # server's today can already have rolled over.
  def days_ago(date)
    return nil if date.nil?

    days = (Runner.current_time_zone.today - date).to_i
    return "today" if days <= 0

    "#{days}d ago"
  end
end
