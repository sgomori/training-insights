---
name: review-trap-time-and-zone
description: Recurring review trap — app zone is UTC but every calendar boundary is the runner's zone, and app/services/ai is fenced from Active Record so "today" must be injected
metadata:
  type: reference
---

`config/application.rb` leaves `config.time_zone` commented out, so `Time.zone`
is UTC. Every period boundary that matters is *not* UTC: `Runner.current_time_zone`
(app/models/runner.rb) is what the MCP tools, `Race#days_until` and
`Race.next_race` bound days by.

**Consequence:** `Date.current` / `Time.current` / `Date.today` anywhere that
feeds analysis or prompt text is a latent one-day bug, invisible in CI (the test
runner is UTC) and wrong for part of every day on a non-UTC deployment. Any
"now" must come from `Runner.current_time_zone`.

Compounding it: `spec/services/ai/no_active_record_spec.rb` forbids anything
under `app/services/ai/` from naming a model or issuing a query. So those
objects cannot reach `Runner` themselves — a date has to be passed in from the
job or controller. Prefer a **required** keyword over a `Date.current` default:
a default would silently resolve to UTC and no spec would exercise it, because
specs pass the value explicitly.

**How to apply:** when reviewing a diff that introduces or moves a notion of
"today" — grep for `Date.current`, `Date.today`, `Time.current`, `Time.now`,
`.beginning_of_day` outside `Runner.current_time_zone`. Push the zone decision
up to the caller that is allowed to touch `Runner`, and reject convenience
defaults on `today:`-style keywords.

Related: [[review-trap-answer-cache-has-no-date]].
