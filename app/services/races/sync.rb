module Races
  # Reconciles the races table with the declared calendar in db/races.yml.
  #
  # The file is the source of truth for what the runner intends to race. It is
  # deliberately not the source of truth for what happened: status, result time
  # and the activity link are derived by Ingestion::RaceLinker, and a re-sync
  # must never undo them. Only the declared columns are written.
  #
  # Nothing is ever deleted. A race the file no longer mentions is reported as
  # unmanaged rather than removed, because destroying it would silently unlink
  # the activity that ran it.
  class Sync
    DEFAULT_PATH = Rails.root.join("db/races.yml")

    REQUIRED_KEYS = %w[name race_date distance_meters].freeze
    PERMITTED_KEYS = (REQUIRED_KEYS + %w[target_time_seconds status notes]).freeze

    # The file may take a race off the schedule or put it back. It may not
    # declare one completed: that is the linker's to set, and only once an
    # activity has actually been matched to it.
    DECLARABLE_STATUSES = %w[upcoming cancelled].freeze

    Result = Struct.new(:created, :updated, :unchanged, :linked, :unmanaged, :errors, keyword_init: true) do
      def ok? = errors.empty?

      def changed? = created.any? || updated.any? || linked.any?
    end

    def self.call(**) = new(**).call

    def initialize(path: DEFAULT_PATH, dry_run: false)
      @path = Pathname.new(path)
      @dry_run = dry_run
      @created = []
      @updated = []
      @unchanged = []
      @linked = []
      @errors = []
      @declared = []
    end

    # All or nothing. A calendar half applied is worse than one not applied at
    # all, because the half that landed is invisible in the diff that follows.
    def call
      entries = load_entries
      return result if @errors.any?

      Race.transaction do
        entries.each_with_index { |entry, index| apply(entry, index) }
        raise ActiveRecord::Rollback if @errors.any?
      end

      if @errors.any?
        @created.clear
        @updated.clear
        return result
      end

      link_unmatched unless @dry_run

      result
    end

    private

    def result
      Result.new(created: @created, updated: @updated, unchanged: @unchanged,
                 linked: @linked, unmanaged: unmanaged_races, errors: @errors)
    end

    def load_entries
      return fail_with("#{@path} does not exist") unless @path.exist?

      parsed = YAML.safe_load(@path.read, permitted_classes: [ Date ]) || []
      return fail_with("#{@path} must contain a list of races") unless parsed.is_a?(Array)

      parsed.each_with_index.filter_map { |entry, index| validate(entry, index) }
    rescue Psych::SyntaxError => e
      fail_with("#{@path} is not valid YAML: #{e.message}")
    end

    # Every entry is checked before any is applied, so one typo reports itself
    # alongside the others rather than hiding behind the first failure.
    def validate(entry, index)
      return note_error(index, "must be a mapping") unless entry.is_a?(Hash)

      entry = entry.transform_keys(&:to_s)

      unknown = entry.keys - PERMITTED_KEYS
      return note_error(index, "has unknown #{'key'.pluralize(unknown.size)}: #{unknown.join(', ')}") if unknown.any?

      missing = REQUIRED_KEYS.reject { |key| entry[key].present? }
      return note_error(index, "is missing #{missing.join(', ')}") if missing.any?

      status = entry["status"]
      if status.present? && DECLARABLE_STATUSES.exclude?(status)
        return note_error(index, "declares status #{status.inspect}; only #{DECLARABLE_STATUSES.join(' or ')} may be declared")
      end

      date = parse_date(entry["race_date"])
      return note_error(index, "has an unparseable race_date: #{entry['race_date'].inspect}") if date.nil?

      entry.merge("race_date" => date)
    end

    def apply(entry, index)
      race = Race.find_or_initialize_by(name: entry["name"], race_date: entry["race_date"])
      race.assign_attributes(entry.slice(*(PERMITTED_KEYS - REQUIRED_KEYS)))
      race.distance_meters = entry["distance_meters"]

      label = "#{entry['name']} (#{entry['race_date']})"
      @declared << label

      if race.new_record?
        @created << label
      elsif race.changed?
        @updated << "#{label}: #{race.changes.keys.sort.join(', ')}"
      else
        @unchanged << label
        return
      end

      return if @dry_run

      race.save!
    rescue ActiveRecord::RecordInvalid => e
      note_error(index, "could not be saved: #{e.record.errors.full_messages.join('; ')}")
    end

    # A race added for a day already ingested has no activity linked, because
    # the linker only runs on arrival. Catch those up here.
    def link_unmatched
      Race
        .where(status: Ingestion::RaceLinker::LINKABLE_STATUSES)
        .where.missing(:activity)
        .find_each do |race|
          @linked << "#{race.name} (#{race.race_date})" if Ingestion::RaceLinker.backfill(race)
        end
    end

    # Rows the file does not mention. Reported rather than deleted, so drift is
    # visible without a destructive sync.
    def unmanaged_races
      Race.order(:race_date).map { |race| "#{race.name} (#{race.race_date})" } - @declared
    end

    def parse_date(value)
      return value if value.is_a?(Date)

      Date.parse(value.to_s)
    rescue Date::Error
      nil
    end

    def note_error(index, message)
      @errors << "entry #{index + 1} #{message}"
      nil
    end

    def fail_with(message)
      @errors << message
      []
    end
  end
end
