# IP-based rate limiting. A baseline against abuse of the public endpoints, not
# a substitute for the API key check in front of the MCP transport.
#
# The thresholds below are deliberate placeholders: the spec calls for setting
# real limits after measuring actual per-call usage, which cannot happen until
# the canonical instance is serving traffic.
class Rack::Attack
  # The MCP endpoint is public and authenticated per key, but an unauthenticated
  # caller can still burn cycles being rejected.
  throttle("mcp/ip", limit: 60, period: 1.minute) do |request|
    request.ip if request.path.start_with?("/mcp")
  end

  # Ingestion is machine-to-machine and low volume: the pipeline delivers one
  # payload per completed activity.
  throttle("webhooks/ip", limit: 30, period: 1.minute) do |request|
    request.ip if request.path.start_with?("/webhooks/")
  end

  # Chat is the only path here that costs money per request, so this is a budget
  # as much as an abuse control. A question already answered against the current
  # data is served from the cache and costs nothing, but it still spends from
  # this allowance — the throttle sits in front of the check that would know.
  throttle("chat/ip", limit: 10, period: 1.hour) do |request|
    request.ip if request.post? && request.path == "/chat"
  end

  # Off by default under test, and deliberately so.
  #
  # It used to be off by accident: the counters live in Rails.cache, which is the
  # null store there, so every count read back as zero and no throttle could ever
  # fire. That held until a spec stood a real store up for its own reasons, at
  # which point unrelated request specs started tripping limits they had never
  # been subject to. The throttles are exercised by the spec that turns this back
  # on, which is the only place they should apply.
  self.enabled = !Rails.env.test?

  # Chat is throttled in a browser; everything else here is throttled in a
  # client that reads JSON. The same body cannot serve both — Turbo declines to
  # render a JSON response to a form submission, so a throttled visitor would
  # get no bubble, no message and no visible change at all. The throttle would
  # be working and would look like nothing happening.
  self.throttled_responder = lambda do |request|
    retry_after = (request.env["rack.attack.match_data"] || {})[:period].to_i

    if request.path == "/chat"
      [ 429,
        { "content-type" => "text/vnd.turbo-stream.html", "retry-after" => retry_after.to_s },
        [ Rack::Attack.throttled_turbo_stream(retry_after) ] ]
    else
      [ 429,
        { "content-type" => "application/json", "retry-after" => retry_after.to_s },
        [ { error: "Rate limit exceeded. Retry in #{retry_after} seconds." }.to_json ]
      ]
    end
  end

  # Hand-built rather than rendered: this runs in middleware, ahead of the
  # controller stack, and standing a renderer up here to append one paragraph
  # would be more machinery than the message deserves.
  #
  # The cost of that is a third copy of the answer bubble's classes, alongside
  # chats/_answer.html.erb and the failure bubble in chat_controller.js. All
  # three have to move together or a throttled visitor gets the message in a
  # stale palette. Tailwind scans this file, so a class left behind here also
  # keeps its utility alive in the build.
  def self.throttled_turbo_stream(retry_after)
    message = "That is as many questions as one visitor gets in an hour. " \
              "Try again in #{(retry_after / 60.0).ceil} minutes — the answers are worth waiting for."

    <<~HTML
      <turbo-stream action="append" target="transcript"><template>
        <article class="space-y-4 text-stone-300">
          <p class="text-[1.0625rem] leading-7">#{ERB::Util.html_escape(message)}</p>
        </article>
      </template></turbo-stream>
    HTML
  end
end
