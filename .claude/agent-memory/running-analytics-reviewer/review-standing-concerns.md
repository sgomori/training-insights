---
name: review-standing-concerns
description: The failure patterns that actually recur in this codebase's aggregation layer — check these first on any new MCP tool or aggregation review.
metadata:
  type: project
---

The arithmetic in `app/mcp/` is unusually careful: nil handling, duration-weighted zone aggregation, ACWR normalisation, and every pace sign have all been checked and were correct. Reviews here should spend their time on the four patterns that *do* recur rather than re-deriving the formulas.

**1. `complete?` means "seven days inside the window", not "seven days elapsed".** `WeeklyBucket#complete?` has no notion of today, so on the last day of the week the in-progress week qualifies as complete and enters ramp rate, monotony, strain and taper ratios alongside finished weeks.
**How to apply:** on any new weekly aggregation, ask what happens when the tool is called on a Sunday.

**2. The structured field carries the caveat; the `notable` prose does not.** Repeatedly, a figure is correctly hedged in its `MetricInterpretation.describe` fragment and then restated as a bare confident sentence in `notable` — taper ratio is the standing example.
**How to apply:** whatever guard suppresses or annotates a value must also gate the signal string that quotes it. `notable` is what a client reads first.

**3. Sample size gets dropped at one hop.** `MetricMath#mean_with_sample` returns both, and callers sometimes take `[:value]` only — `get_pace_progression`'s series rows do, so a bucket mean backed by one activity is indistinguishable from one backed by fifteen.
**How to apply:** grep for `mean_with_sample(...)[:value]`. Per-metric sample size, not per-bucket activity count, is what qualifies a per-metric average.

**4. A `MetricInterpretation` definition can exist and never be wired up.** `long_run_pct_of_race_distance` is defined with the guidance that makes the figure readable and is used by no tool.
**How to apply:** when reviewing, diff `DEFINITIONS.keys` against actual `describe(` call sites.

Definitions of the conventions themselves: [[analytical-conventions]]
