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
      { rss_mb: rss_mb }.compact.merge(STATS.index_with { |stat| GC.stat(stat) })
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
