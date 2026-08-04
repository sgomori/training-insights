---
name: review-trap-connection-pools
description: Recurring review trap — this app has four DB specs on one Postgres, and Puma request threads draw on the queue pool too
metadata:
  type: reference
---

Connection-pool findings recur in this repo and are easy to get wrong. The
durable facts to check against, not to re-derive each time:

- `config/database.yml` defines four production specs (`primary`, `cache`,
  `queue`, `cable`) that all point at the same physical Render Postgres and are
  separated only by `migrations_paths`. Each has its own independent pool, so
  "the pool" is always ambiguous — name the spec in the finding.
- Puma **request** threads check out of the `queue` pool, not just the `primary`
  pool: `Webhooks::ActivitiesController#create` calls
  `RegenerateContentJob.perform_later`, which writes `solid_queue_jobs` through
  the queue connection while the request thread already holds a primary
  connection. Any queue-pool sizing rationale that only counts Solid Queue's own
  threads is incomplete.
- Solid Queue's own sizing warning
  (`Configuration#warn_about_incorrectly_sized_thread_pool`) only checks
  `max worker threads + 2` against the queue pool, so it stays silent well below
  the real peak. Do not treat its absence as evidence the pool is adequate.
- `Webhooks::BaseController` has a `rescue_from StandardError` that records a
  failed delivery — but the recording path is `WebhookLog.create!`, which needs a
  **primary** connection. Under primary-pool exhaustion the rescue fires and then
  fails too, falling through to `Rails.logger.error`. Comments claiming the
  controller "does not rescue" ConnectionTimeoutError are stale.

**How to apply:** whenever a diff changes thread counts, `RAILS_MAX_THREADS`,
`config/queue.yml`, or any `pool:` value, recompute peak concurrent checkouts
per spec and check the prose comment matches the number actually shipped.
