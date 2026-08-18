---
name: review-trap-solid-defaults
description: Recurring review trap — Solid Queue's recurring-task queue and Solid Cache's max_age both bite this deployment silently, and neither shows up in the test suite
metadata:
  type: reference
---

Two library defaults in this repo fail silently in production and pass every
spec. Check both whenever a diff touches `config/queue.yml`, `config/cache.yml`,
`config/recurring.yml`, or anything that writes to `Rails.cache`.

## Solid Queue: `solid_queue_recurring` is a real queue

`config/recurring.yml` uses `command:` entries, not `class:`. A command task
enqueues `SolidQueue::RecurringJob`, which is `queue_as :solid_queue_recurring`.
`RecurringTask#enqueue_options` omits `queue` unless the YAML entry sets one, so
the job class default wins.

That means **any `workers:` block that names queues explicitly instead of `"*"`
must include `solid_queue_recurring`**, or the finished-job pruning and the
hourly `Ops::MemoryReport` stop running while unclaimed rows pile up in
`solid_queue_jobs`. Nothing raises and no spec covers it.

Verify with:

```
bin/rails runner 't = SolidQueue::RecurringTask.from_configuration("x", command: "1", schedule: "every hour"); p t.queue_name, t.send(:job_class).queue_name, t.send(:enqueue_options)'
```

## Solid Cache: `max_age` defaults to 2 weeks and re-writes do not reset it

`config/cache.yml` leaves `max_age` commented out, so `SolidCache::Store::Expiry`
uses its `2.weeks` default. `max_size` is set but `cache_full?` is false in
normal operation, so the age branch is the one that runs.

The sharp edge: `SolidCache::Entry.write_multi` upserts with
`update_only: [:key, :value, :byte_size]`, so **rewriting a key does not refresh
`created_at`**. An entry written once and refreshed forever is still an expiry
candidate two weeks after its *first* write. `expiry_candidate_ids` orders by
`id`, so the oldest keys are also the first reached. Expiry fires on roughly one
in fifty writes.

Consequence for this app: anything long-lived kept in `Rails.cache` under a
stable key — the standing summary in `Answers::Cache.content_key` above all —
will disappear at an arbitrary moment regardless of how recently it was
regenerated. Long-lived generated artefacts belong in a table, not the cache.

**How to apply:** treat "unversioned cache key + regenerated in place" as a bug
pattern here, not a design. And recompute queue routing from the job class
default, never from the queue name the author intended.

See also [[review-trap-connection-pools]] for the pool-sizing half of the same
config surface.
