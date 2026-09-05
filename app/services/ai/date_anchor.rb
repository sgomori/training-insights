module Ai
  # The one fact both prompts need that no tool result reliably supplies: what
  # day it is.
  #
  # Without it the model dates a question from its own training rather than
  # from the calendar, so "the run on 30 August" resolves to whichever year it
  # last saw most of, and the tools are asked about a day that may hold nothing.
  # The tools already work in the runner's zone, so the date is passed in from
  # the caller rather than computed here; this module knows nothing about the
  # runner and issues no query.
  module DateAnchor
    def self.for(today)
      earlier = today - 7
      later = today + 7
      # A worked example has to name a day that exists in the year it names.
      later += 1 if later.month == 2 && later.day == 29

      <<~TEXT.strip
        Today is #{today.strftime('%A %-d %B %Y')}. Read every date against it.
        "Recent" means the days and weeks before today. A date given without a
        year means its most recent occurrence on or before today, so
        #{day_and_month(earlier)} means #{earlier.year} and #{day_and_month(later)} means #{later.year - 1}.
        The exception is something still to come, such as an upcoming race,
        which means the next occurrence on or after today. Where you resolve a
        date this way, say which day you took it to be.
      TEXT
    end

    def self.day_and_month(date)
      date.strftime("%-d %B")
    end
    private_class_method :day_and_month
  end
end
