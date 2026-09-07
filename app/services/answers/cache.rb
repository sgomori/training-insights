module Answers
  # Where generated prose is kept, and the one place that knows when it went
  # stale.
  #
  # This is deliberately outside app/services/ai. Those objects must not be able
  # to reach a record at all, and deriving a cache key is a database read — so
  # the seam between "what the model is told" and "what the database knows" runs
  # right here.
  #
  # Invalidation is by namespace rather than by deletion. Every key carries a
  # version derived from the newest record, so one activity arriving orphans
  # every answer at once without anything having to enumerate them. Entries left
  # behind are unreachable and small; the cache store evicts them under its own
  # size cap, which is a better fit than an expiry that would blank the site's
  # summary during a long injury layoff.
  module Cache
    class << self
      def content
        Rails.cache.read(content_key)
      end

      def write_content(text)
        Rails.cache.write(content_key, text)
      end

      # Read against the version in force now. Written under the version the
      # caller captured when the question was asked, which is not always the
      # same one: a turn takes long enough for a run to land in the middle of
      # it, and an answer computed on the old corpus must not be filed under the
      # new one.
      def answer_to(question, version: self.version)
        Rails.cache.read(chat_key(question, version))
      end

      def write_answer(question, answer, version:)
        Rails.cache.write(chat_key(question, version), answer)
      end

      # Unversioned, unlike an answer. The summary is replaced by the next
      # ingestion rather than invalidated by it: a new run arriving makes it a
      # run out of date, not wrong, and it is narrative prose about the last few
      # weeks rather than a figure that has moved.
      #
      # Versioning it would mean a failed regeneration blanks the top of the site
      # until the runner next goes out, which is a worse answer than a summary
      # that is a day behind.
      def content_key
        "content"
      end

      # Questions are matched on their meaning rather than their typing, so
      # "How is the marathon buildup going?" and "how is the marathon buildup
      # going" are one entry rather than two.
      def chat_key(question, version)
        "chat:#{version}:#{Digest::SHA256.hexdigest(normalise(question))}"
      end

      # What an answer is valid against: the newest record, and the day it was
      # asked on. The day is there because the prompt states today's date and
      # the questions worth caching are relative to it — "last Sunday", "this
      # week", "how many days to the race" — so an answer that outlived its day
      # would be served as current while quietly describing an earlier one. The
      # cost is that a hit needs the same question on the same day, which on a
      # site with a handful of visitors is the only kind of hit there was.
      def version(today = Runner.current_time_zone.today)
        "#{data_version}:#{today}"
      end

      def normalise(question)
        question.to_s.strip.downcase.squish
      end

      # Races count alongside activities: a corrected finish time or a new date
      # changes what the readiness tools return, and an answer written before it
      # would still be sitting in the cache.
      def data_version
        newest = [ Activity.maximum(:updated_at), Race.maximum(:updated_at) ].compact.max
        newest ? newest.utc.iso8601(6) : "empty"
      end
    end
  end
end
