# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]

# The two below are a memory guard rather than a privacy one, and are separated
# from the list above so they do not read as sensitive.
#
# ActionController::LogSubscriber writes "Parameters: #{params.inspect}" at info
# level, which production logs at. An activity payload carries nine per-second
# streams, so a two-hour run inspects to several megabytes of numbers — on top
# of the raw body, Rails' own parse of it, and the filtered copy the log line is
# built from, all live at once and across up to three request threads. Filtering
# replaces the arrays before they are rendered.
#
# Anchored rather than given as symbols: a symbol matches any key containing it,
# so :laps would also filter an `elapsed_time` the sender may add later, and
# Active Record applies the same list to attribute inspection.
Rails.application.config.filter_parameters += [ /\Astreams\z/, /\Alaps\z/ ]
