# Runs a block against a real cache store.
#
# The test environment uses the null store, so every write succeeds and every
# read returns nothing. That is the right default — it keeps one example's cached
# answer out of the next one — but it makes caching behaviour untestable, so the
# specs that are about the cache stand a memory store up for their duration.
module CacheStore
  def with_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    yield
  ensure
    Rails.cache = original
  end
end

RSpec.configure do |config|
  config.include CacheStore
end
