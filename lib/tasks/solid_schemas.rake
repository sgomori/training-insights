namespace :db do
  # The cache, queue and cable connections all point at DATABASE_URL — the same
  # database the app itself uses. `db:prepare` loads a schema only when the
  # database named by a configuration does not yet exist, so the primary creates
  # it and loads db/schema.rb, and the other three are then skipped as already
  # prepared. Their tables are never created, and Puma boots and binds before
  # the Solid Queue supervisor dies on its first query against a missing table.
  #
  # Loading them unconditionally is not the answer either: every solid schema
  # file declares `force: :cascade`, so a load on each deploy would drop
  # in-flight jobs and flush the cache. Hence the sentinel check.
  SOLID_SENTINELS = {
    cache: "solid_cache_entries",
    queue: "solid_queue_jobs",
    cable: "solid_cable_messages"
  }.freeze

  desc "Load the Solid Cache, Queue and Cable schemas when their tables are absent"
  task load_solid_schemas: :environment do
    SOLID_SENTINELS.each do |name, sentinel|
      if ActiveRecord::Base.connection_pool.with_connection { |c| c.table_exists?(sentinel) }
        puts "db:load_solid_schemas: #{name} already present"
        next
      end

      puts "db:load_solid_schemas: loading db/#{name}_schema.rb"

      # db:schema:load is destructive by nature, so Rails guards it behind
      # db:check_protected_environments and refuses to touch a production
      # database. Here there is nothing to protect: the sentinel above proved
      # the tables are absent, and the guard is lifted for this one load and
      # restored immediately. The primary's schema never travels this path.
      previous = ENV["DISABLE_DATABASE_ENVIRONMENT_CHECK"]
      ENV["DISABLE_DATABASE_ENVIRONMENT_CHECK"] = "1"
      begin
        Rake::Task["db:schema:load:#{name}"].invoke
      ensure
        ENV["DISABLE_DATABASE_ENVIRONMENT_CHECK"] = previous
      end
    end
  end
end
