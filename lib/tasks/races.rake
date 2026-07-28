namespace :races do
  desc "Apply the declared race calendar in db/races.yml (DRY_RUN=1 to preview)"
  task sync: :environment do
    dry_run = ENV["DRY_RUN"].present?
    result = Races::Sync.call(dry_run: dry_run)

    if result.errors.any?
      warn "Refused to sync — nothing was written:"
      result.errors.each { |error| warn "  #{error}" }
      abort
    end

    puts "Previewing db/races.yml — nothing will be written." if dry_run

    report = lambda do |label, lines|
      next if lines.empty?

      puts "#{label} (#{lines.size}):"
      lines.each { |line| puts "  #{line}" }
    end

    report.call("Created", result.created)
    report.call("Updated", result.updated)
    report.call("Linked to an activity", result.linked)
    report.call("Unmanaged — present in the database but not in the file", result.unmanaged)
    puts "Unchanged: #{result.unchanged.size}" if result.unchanged.any?
    puts "Nothing to do." unless result.changed?
  end
end
