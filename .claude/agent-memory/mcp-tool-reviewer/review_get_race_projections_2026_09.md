---
name: review-get-race-projections-2026-09
description: Findings on get_race_projections (eleventh tool) and the projection_distance_ratio bands, 2026-09-05, report-only and left unfixed — check each before repeating
metadata:
  type: project
---

Reviewed `app/mcp/analytical_tools/get_race_projections.rb`, its spec, the new
`projection_distance_ratio` definition in `metric_interpretation.rb` and the
`riegel_time` / `hard_zone_share` / `hard_effort?` extraction into
`metric_math.rb`, at commits e67ed2d/e4564f3 on `main`, 2026-09-05. Report-only
by instruction, so everything below was **raised and left open**. Verify against
current code before repeating.

Design findings, ranked as reported:

1. `projection_distance_ratio` bands are asymmetric on a log scale and mislabel
   the canonical case. Bands are half-open `[min, max)`, so ratio exactly 2.0
   lands in "wide" — that is 5k→10k *and* half→marathon. Probed: a 5.00km race
   projected to 10k returns `distance_ratio: 2.0, reliability: "wide"`, while a
   5.02km training effort returns `1.99, "close"`. 10k→5k (0.5) returns "close",
   which runs against the definition's own guidance that a long-to-short
   projection "says nothing about the speed the runner has or lacks", and against
   `nearest_race_signals`' comment asserting 0.5 and 2 are the same log distance.
   The band is also read off the *rounded* ratio.
2. The response is reference-major while the question is target-major. No
   `by_target` rollup, so answering "what could he run for a 10k" means walking
   every reference. Probed at 6 races: 28 projections, no grouping.
3. The race-vs-training comparison — the tool's whole reason to exist — is left
   for the client. Probed a case where a submaximal 5k training effort projected
   a 10k *faster* than the actual 10k race, and nothing in `notable` said so.
4. `fitness_then_vs_now.basis` says "Training efforts only" but `weekly_km` uses
   `window.total_distance_meters`, which counts races. With a race inside its own
   overlapping `now` window the race inflated the volume it was compared against:
   `weekly_km_change_pct: 15.3` was entirely the race itself.
5. `nearest_race_signals` fires once per target unconditionally — with one race
   and four targets, four near-identical sentences repeating numbers already on
   the projections. Same "loud where nothing happened" failure as describe_run's
   auto-lap caveat.
6. Two verdict crossings in `notable`: "that race projects conservatively /
   generously" fires on *any* nonzero EF change (sample guard, no effect-size
   guard), and "sits well below what a maximal effort would produce" is
   unquantified judgement.
7. References are ranked on raw `average_pace_per_km`, never on grade-adjusted
   pace, in a tool whose output is a claim about current ability. Only the winner
   is returned, so the client cannot re-rank.
8. The `now` fitness side is byte-identical across every race reference and is
   repeated verbatim once per race.

Defects: one query per race in `fitness_then_vs_now` (20 queries at 6 races);
four queries in `training_references` over disjoint distance ranges;
`windows.races` reports `days: 365` over an inclusive 366-day span while
`training_efforts` is correct; the per-reference `.compact` drops nullable
metrics — sharpest on tri-state `hard_effort`, where the code has to use
`ref.key?(:hard_effort)` to count unknowns; `time_seconds` is rebuilt from
pace × distance rather than read from `duration_seconds`; `distances: []`
silently means all four.

Assessed as **well designed and worth reusing**: hoisting the band vocabulary
once into a top-level `reliability` block so each projection carries only ratio
plus label; `attempts_considered` beside a best-of pick (the sample size behind a
*maximum*, which most tools omit); refusing to name a single estimate and stating
the maximal/submaximal distinction as methodology rather than preference; naming
an untimed race in `notable` instead of dropping it; `hard_effort?` returning nil
rather than false; and adding cross-references to `get_personal_records` and
`get_race_readiness` descriptions so a client picks the right tool. Determinism is
clean — ordered `Race.completed`, fixed bucket order, `started_at` tiebreak, one
clock read.

Passes the abstraction test comfortably: staleness of evidence, whether training
is hard enough to say anything, and how aerobic fitness has moved since a given
race are all answerable from one call.

Note: the registry is `app/mcp/tool_registry.rb`, not `app/mcp/registry.rb` as
review briefs sometimes state.

**Why:** contract findings that get harder to change once external MCP clients
bind to the response keys, and the reviewer was asked not to touch code.

**How to apply:** if asked to review this tool again, check these first and say
which are fixed rather than re-deriving them.

Related: [[conventions-tool-shaping]], [[review-tool-layer-2026-07]],
[[review-describe-run-2026-08]]

**Status 2026-09-06 (verified against `main` at a6284f1 plus branch `review-under-fable`):** all eight design findings are fixed — bands `close`/`wide`/`far` over the folded unrounded ratio, `by_target`, `training_beats_race_signals`, `weekly_km` excluding the race, `far_reference_signals` only where no close reference exists, effect-size guards on the fitness signal, grade-adjusted ranking with `ranked_on`, and a single `current_fitness` block. Of the defects, the 366-day window, `time_seconds` from `duration_seconds` with `time_basis`, and the empty `distances` note are fixed; per-race fitness queries and the per-reference `.compact` were not re-checked.
