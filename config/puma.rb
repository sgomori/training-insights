# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1. You can set it to `auto` to automatically start a worker
# for each available processor.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments.
#
# `fork`, the plugin's default, forks a process per configured worker,
# dispatcher and scheduler — four children beside Puma, each carrying its own
# copy of the eager-loaded application. Copy-on-write shares those pages at
# first, but Ruby's GC writes mark bits into object headers, so the children
# drift toward independent heaps over a few hours. That is what reached the
# 512MB ceiling with no traffic at all on 2026-08-03.
#
# `async` runs the same roles as threads here instead. Solid Queue reserves it
# for callers with a specific reason; being memory-bound is that reason. Two
# tradeoffs: jobs lose process isolation from the web server, and a job that
# outlives `config.solid_queue.shutdown_timeout` is killed by an `exit!` in
# this process rather than in a child — see config/environments/production.rb.
# Job threads remain separate from Puma's request pool either way.
#
# Two ordering constraints, both of which fail at boot if broken:
# `solid_queue_mode` is defined by the plugin, so it must follow the `plugin`
# call that requires it; and Puma evaluates this file before Rails, so Active
# Support is absent and `present?` is not available for the guard.
if %w[true 1 yes].include?(ENV["SOLID_QUEUE_IN_PUMA"].to_s.strip.downcase)
  plugin :solid_queue
  solid_queue_mode :async
end

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
