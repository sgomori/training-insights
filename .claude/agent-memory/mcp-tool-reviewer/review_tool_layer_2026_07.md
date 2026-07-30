---
name: review-tool-layer-2026-07
description: Findings raised against the nine-tool MCP layer on 2026-07-29 and left unfixed by request — check whether each still stands before re-reviewing
metadata:
  type: project
---

Reviewed the full nine-tool inventory (commits 264f636..84dd089 on `dev`) on
2026-07-29. Instruction was report-only, no code changes, so the findings below
were **raised and left open**. Verify against current code before repeating them.

Ranked as reported:

1. `GetRaceReadiness#comparison_to_past_buildups` — past buildups use a fixed
   112-day window while the target buildup is truncated to available history, so
   `average_weekly_km` is diluted by pre-ingestion weeks and `weeks_of_history`
   always reports ~15. No `this_buildup` row in the same key shape. Probed: a
   past race with one week of history reported `peak_week_km: 45.0,
   average_weekly_km: 2.8, weeks_of_history: 15`.
2. `GetPaceProgression` — `sufficient_sample` counts matching activities, not the
   activities carrying each metric, so a bucket of 4 can report a
   grade-adjusted-pace mean drawn from 1.
3. `GetPaceProgression#series_buckets` — one DB query per bucket. 113 queries at
   `days: 730, bucket_weeks: 1`.
4. `MetricInterpretation.describe` — the trailing `.compact` drops the `value`
   key entirely when the value is nil, in every tool.
5. `GetRaceReadiness` — `race.activity` N+1 in `result_seconds`; `past_races`
   queried twice.

Lower: unordered `Activity.pluck` in `GetPersonalRecords#notable_efforts` makes
biggest-week ties depend on DB row order; aggregating tools do not scope to
running (plan's open question 4); `TrainingWindow#zones` drops
`hours_contributing` in the empty case.

**Why:** these are design and contract findings that get harder to change once
external MCP clients depend on the response keys, and the reviewer was asked not
to touch code.

**How to apply:** if asked to review this layer again, start by checking these
five. If they are fixed, say so rather than re-deriving. Assessed as *well
designed* and worth reusing: `TrainingWindow` as a composition target,
`key_workouts` with `qualified_as`, the suppressed-not-nulled delta pattern, and
`spec/mcp/tool_registry_spec.rb`'s empty/thin/nil-corpus loop over every
registered tool.

Related: [[conventions-tool-shaping]]
