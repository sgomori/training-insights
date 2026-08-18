# Swaps environment variables for the duration of a block and puts them back.
#
# Configuration is per-deployment here rather than per-user, so most of it
# arrives through the environment and several specs need to stand a value up
# before the code under test reads it. Restoring the original — including an
# original of nil — is what keeps one example from leaking into the next.
module EnvironmentVariables
  def with_env(values)
    originals = values.keys.index_with { |key| ENV[key.to_s] }
    values.each { |key, value| ENV[key.to_s] = value }

    yield
  ensure
    originals.each { |key, value| ENV[key.to_s] = value }
  end
end

RSpec.configure do |config|
  config.include EnvironmentVariables
end
