---
name: review-describe-run-anchors-2026-09
description: Findings on the anchor-chat-in-time change to describe_run's miss message and the ToolRegistry date paragraph, 2026-09-05, report-only and left unfixed
metadata:
  type: project
---

Reviewed the `app/mcp/` half of branch `anchor-chat-in-time` on 2026-09-05
(uncommitted): `describe_run`'s empty-day miss now carries today's date, the
latest activity, the neighbours of the requested day and the same day in other
years, and `ToolRegistry::INSTRUCTIONS` gained a paragraph on reading dates.
Report-only by instruction, so everything below was **raised and left open**.

Ranked as reported:

1. The anchor fires only on a miss. A wrong year that *hits* an activity still
   returns a full description with nothing saying what today is — `selection`
   has no `as_of`, and describe_run is the one tool carrying no
   `training_context`, which is where the new instructions paragraph points a
   client for the anchor.
2. The anchors are prose only; `structured_content` is nil on a miss. The gem
   allows `structured_content` alongside `error: true`, and no tool on this
   server declares an `output_schema`, so mirroring the anchors as data is free
   and non-breaking.
3. The `started_at` miss is still bare — the same wrong-year hazard on the
   parameter clients round-trip out of `get_activities`.
4. `other_years_clause` is unbounded: one indexed query and one named date per
   year of history. Probed at 8 years it listed 7 same-day matches in one
   sentence and cost 13 queries on the miss path.
5. When the nearest neighbour is also the most recent activity the same date is
   named twice in adjacent sentences.

Instructions: "A date given without one means its most recent occurrence on or
before today" reads as though the server resolves a year-less argument. It does
not — `Date.strptime` rejects `"08-30"`. `Ai::DateAnchor` phrases the same rule
correctly by telling the model to resolve it before calling.

Assessed as **well done and worth reusing**: the leap-day guard via
`Date.valid_date?`, taking the earliest year through `.in_time_zone(zone)`, the
nil-distance guard in `brief`, singular/plural prose branches, and specs that
cover the empty corpus, the one-sided history and the leap day. No AI, no
network, and the only clock read is `zone.today`, which is the point of the
change.

Also: the "a miss returns a bare error where a shaped miss naming nearby dates
would save a call" defect from [[review-describe-run-2026-08]] is what this
branch answers, in prose rather than in structure.

**Why:** contract findings that get harder to change once external clients bind
to the miss text, and the reviewer was asked not to touch code.

**How to apply:** if asked to review `describe_run` or the date anchoring again,
check these five first and say which are fixed rather than re-deriving them.

Related: [[review-describe-run-2026-08]], [[conventions-tool-shaping]],
[[review-tool-layer-2026-07]]

**Status 2026-09-06 (verified against `main` at a6284f1 plus branch `review-under-fable`):** all five findings are fixed — `as_of` and `days_ago` on every hit, anchors mirrored into `structured_content`, the `started_at` miss carries them, other-years is bounded to three candidate years, and a neighbour that is the latest activity is dropped. The instructions paragraph now tells the client to resolve the year before calling.
