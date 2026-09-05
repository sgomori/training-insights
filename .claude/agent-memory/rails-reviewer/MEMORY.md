# Memory

- [Docs that drift on infra changes](reference-docs-that-drift.md) — PHASE_3_PLAN.md is git-excluded and the deploy skill restates the memory story; check both.
- [Connection pool review trap](review-trap-connection-pools.md) — four DB specs on one Postgres; Puma request threads draw on the queue pool too.
- [Solid Queue and Solid Cache defaults](review-trap-solid-defaults.md) — named workers must include solid_queue_recurring; cache max_age expires re-written keys.
- [Time and zone trap](review-trap-time-and-zone.md) — app zone is UTC, analysis zone is the runner's; app/services/ai cannot query, so "today" is injected.
- [Answer cache carries no date](review-trap-answer-cache-has-no-date.md) — chat keys are data version plus question text only; date-dependent prose outlives its day.
