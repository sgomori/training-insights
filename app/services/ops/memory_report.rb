module Ops
  # Logs one line describing the process's memory use.
  #
  # The deployment is a single Ruby process on a 512MB instance, and until this
  # existed the only evidence of how close it ran to that ceiling was Render's
  # dashboard graph and, when it went over, the restart notification. Neither
  # says whether resident memory is growing, and a graph is gone by the time
  # anyone asks. An hourly line in the log stream turns the next alert into a
  # lookup.
  #
  # Reported alongside RSS because RSS alone does not distinguish the two ways
  # this process can grow: `heap_live_slots` rising means objects are being
  # retained, whereas RSS rising while live slots hold flat is fragmentation or
  # allocator behaviour.
  #
  # This measures whichever process runs the job, which is the web process only
  # because Solid Queue is embedded in async mode. Going back to fork mode would
  # quietly repoint it at a worker child — the one number nobody wants.
  #
  # The line also carries the registered workers and the age of the oldest
  # heartbeat among them. /up passes with a job thread dead, and this report
  # runs on the default pool, so a line arriving at all proves that pool alive;
  # the chat pool is the one nothing else vouches for. Solid Queue prunes a dead
  # worker's row within about ten minutes, so a stale age catches a fresh death
  # and the count dropping below the configured pools catches an old one.
  class MemoryReport
    STATS = %i[heap_live_slots heap_free_slots malloc_increase_bytes major_gc_count].freeze

    def self.call(...) = new(...).call

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    def call
      @logger.info("memory #{measurements.map { |key, value| "#{key}=#{value}" }.join(" ")}")
    end

    private

    # Read one statistic at a time so the line's field order follows STATS
    # rather than whatever order GC.stat happens to emit. A report meant to be
    # grepped and compared across months should not reorder itself under a
    # Ruby upgrade.
    def measurements
      { rss_mb: rss_mb }.compact
        .merge(STATS.index_with { |stat| GC.stat(stat) })
        .merge(workers)
    end

    # Registered workers and the age of the oldest heartbeat among them, in
    # seconds: the question is whether any worker is stale, so the newest would
    # hide the answer. One read, so a prune between two of them cannot report a
    # count of none beside an age. Omitted rather than fatal where the queue
    # tables cannot be reached, so a report about memory is never lost to a
    # question about the queue.
    def workers
      heartbeats = worker_heartbeats
      oldest = heartbeats.min

      {
        workers: heartbeats.size,
        worker_heartbeat_age_s: oldest ? (Time.current - oldest).round.clamp(0..) : "none"
      }
    rescue ActiveRecord::ActiveRecordError
      {}
    end

    def worker_heartbeats
      SolidQueue::Process.where(kind: "Worker").pluck(:last_heartbeat_at)
    end

    # VmRSS is reported in kilobytes. Linux-only, which the deployment target
    # and the development containers both are; a platform without it reports
    # nil rather than failing the task it is attached to.
    def rss_mb
      status = File.read("/proc/self/status")
      kb = status[/^VmRSS:\s+(\d+) kB$/, 1]
      (kb.to_i / 1024.0).round(1) if kb
    rescue SystemCallError
      nil
    end
  end
end
