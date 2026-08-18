# Memory

- [Docs that drift on infra changes](reference-docs-that-drift.md) — PHASE_3_PLAN.md is git-excluded and the deploy skill restates the memory story; check both.
- [Connection pool review trap](review-trap-connection-pools.md) — four DB specs on one Postgres; Puma request threads draw on the queue pool too.
- [Solid Queue and Solid Cache defaults](review-trap-solid-defaults.md) — named workers must include solid_queue_recurring; cache max_age expires re-written keys.
