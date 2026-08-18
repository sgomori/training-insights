---
name: review-describe-run-2026-08
description: Findings raised against describe_run and LapSegmentation on branch chat-surface, 2026-08-04, report-only and left unfixed — check each against current code before repeating
metadata:
  type: project
---

Reviewed the tenth tool, `describe_run` (`app/mcp/analytical_tools/describe_run.rb`
plus `app/mcp/lap_segmentation.rb`), on branch `chat-surface` at commit 5aa9848,
on 2026-08-04. Instruction was report-only, so everything below was **raised and
left open**. Verify before repeating.

Design findings, ranked as reported:

1. Reps are collapsed past the point of answering the obvious follow-up.
   `present_repeats` returns count, median rep distance, aggregate rep pace and a
   spread, so a fading set (260,265,272,280,291) and a negative-split set produce
   byte-identical output. Direction is the first question about any workout and
   no other tool can recover it. Wanted: signed drift, or the per-rep paces.
2. The `activity` headline omits `aerobic_decoupling_pct`, `efficiency_factor`
   and `grade_adjusted_efficiency_factor`, which `get_activities` carries — so
   the single-activity tool returns *less* about the activity than the generic
   escape hatch. describe_run is also the only tool that knows whether the run
   was steady, so it is the natural place to attach the "decoupling does not
   apply to an interval session" caveat.
3. No comparison point of any kind. Deliberately no `training_context` (right
   call — that block is as-of-today and would be wrong for a run from March), but
   the argument is for an as-of-the-run context, not for none.
4. `notable` carries the auto-lap caveat, which fires on nearly every activity,
   and stays silent about a sustained faster phase. Loud where nothing happened.
5. `structure.structure` — key duplicated at two nesting levels. Free to rename
   before external clients bind to it.

Defects: `headline`'s trailing `.compact`; "Only 1 usable lap **were** recorded";
exact `find_by(started_at:)` breaks a round-trip of `get_activities`' `iso8601`
if the column ever holds sub-second precision (latent — FIT carries whole
seconds); the `started_at` path never reports the other activities that day; a
miss returns a bare error where a shaped miss naming nearby activity dates would
save a call.

Assessed as **well designed and worth reusing**: 3 queries with no N+1 and both
indexes present; every threshold relative to the run's own median lap rather than
absolute; `uniform_lap_distance`'s short-final-lap test with a "where unsure,
return nothing" rule; and the disagreement-as-finding pattern (laps read
continuous, whole-run `pace_cv` reads high, so the variation fell inside the
laps) — the same move the server instructions already make for raw vs.
grade-adjusted pace.

Also observed: finding 4 of [[review-tool-layer-2026-07]] (the `.compact`
dropping `value` in `MetricInterpretation.describe`) **is fixed**, and the
reasoning is now a comment there. The other four were not re-checked.

**Why:** report-only by instruction, and these are contract findings that get
harder to change once external MCP clients bind to the response keys.

**How to apply:** if asked to review `describe_run` again, check these first and
say which are fixed rather than re-deriving them.

Related: [[conventions-tool-shaping]], [[review-tool-layer-2026-07]]
