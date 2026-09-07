---
name: review-standing-concerns
description: The failure patterns that actually recur in this codebase's aggregation layer — check these first on any new MCP tool or aggregation review.
metadata:
  type: project
---

The arithmetic in `app/mcp/` is unusually careful: nil handling, duration-weighted zone aggregation, ACWR normalisation, and every pace sign have all been checked and were correct. Reviews here should spend their time on the patterns below rather than re-deriving the formulas.

**Patterns 1-8 were all found and fixed** (verified against `main` at a6284f1 plus branch `review-under-fable` on 2026-09-06). They stay listed because they are the right things to check first on new code, and because the *shape* of each recurs even after the instance is gone.

**1. `complete?` meaning "seven days inside the window" rather than "seven days elapsed".** Fixed by `WeeklyBucket#comparable? = complete? && !in_progress?`.
**How to apply:** on any new weekly aggregation, ask what happens when the tool is called on a Sunday.

**2. The structured field carries the caveat; the `notable` prose does not.** Fixed for taper — the signal is withheld for a week in progress while `taper_status` still reports the raw ratio and says why it is not banded.
**How to apply:** whatever guard suppresses or annotates a value must also gate the signal string that quotes it. `notable` is what a client reads first. This one recurs constantly — see pattern 9.

**3. Sample size gets dropped at one hop.** Mostly fixed via per-metric `sample_size`, but **not entirely**: `get_training_load.rb:126` still does `mean_with_sample(changes, precision: 1)[:value]`, and the only `sample_size` in that block counts weeks (n) while `changes` holds transitions (n−1). A client reading `sample_size: 4` beside `mean_of_weekly_changes_pct` thinks four changes; there were three.
**How to apply:** grep for `mean_with_sample(...)[:value]` on every review. Per-metric sample size, not per-bucket activity count, is what qualifies a per-metric average.

**4. A `MetricInterpretation` definition can exist and never be wired up.** Fixed — `long_run_pct_of_race_distance` is used by `get_race_readiness`.
**How to apply:** diff `DEFINITIONS.keys` against actual `describe(` call sites.

**5. A reference statistic chosen for robustness without checking where it lands on a bimodal sample.** Fixed — `LapSegmentation#recovery?` is any non-faster phase, so a `steady` connector separates two reps.
**How to apply:** whenever a reference is a median, mean or quantile over a sample the tool itself expects to be multi-modal, sweep the parameter that moves the modes apart and check the classification at each step. Ask which cluster the statistic sits in, not just whether it is robust.

**6. Unweighted means over unequal-length laps.** Fixed — lap heart rate is duration-weighted and `weighted_pace` is distance-weighted.
**How to apply:** any mean over laps needs `Σ(value × duration) / Σ(duration)` over the laps that actually carried the value, with the count of contributing laps alongside.

**7. A band selected from a value already rounded for display, and half-open bands broken on a multiplicative scale.** Fixed — projections band the unrounded folded ratio.
**How to apply:** band the unrounded value and report the rounded one separately. When the metric is a ratio, fold it or mirror the bounds, and check both directions of the most common pair.

**8. A qualitative claim in `description` or a `BASIS` constant is not gated the way a per-figure caveat is.** Fixed — the "a training projection is a floor" claim is gated on the ratio.
**How to apply:** static basis prose applies to every row in the response, including the rows the tool itself bands as unreliable. Check the worst row before writing an unconditional claim.

**9. A median is emitted as the single description of a set whose members are allowed to vary by a whole tolerance constant, with no spread field beside it.** Open as of 2026-09-06. `LapSegmentation` admits reps up to `REP_DISTANCE_RATIO = 1.4` apart and then reports `rep_distance_km` as their median, so a pyramid apex of 1200/1600/1200 m surfaces as `reps: 3, rep_distance_km: 1.2` and `describe_run`'s notable line reads "3 repetitions of about 1.2 km". The same hash gets this right for the other two dimensions: `rep_pace_spread_seconds` for pace, `uneven_recoveries` for recovery.
**Why:** the tolerance is what makes the aggregate possible, so the aggregate has to disclose how much of it was used. A reader cannot tell 1.0/1.0/1.0 from 1.0/1.2/1.4.
**How to apply:** wherever a constant admits members into a group and a central statistic then describes the group, emit the range too — conditionally, in the `uneven_recoveries` shape, so a uniform set stays quiet. Applies well beyond laps: any `DistanceBucket::STANDARD` aggregate has the same structure.

**10. Documentation of a degradation drifts out of step with the code that degrades.** Open as of 2026-09-06. `LapSegmentation`'s header describes which shapes it declines to read; the shapes have changed twice under it and the header has been rewritten each time from the motivating example rather than from a sweep. It currently claims a symmetric pyramid "collapses nothing", which holds only for a geometric pyramid (steps ≥ 1.4×) and is false for the additive pyramids people actually run.
**How to apply:** the header of a heuristic module is a claim about every input, not about the one that prompted the change. Re-run the shape sweep before rewriting it. A standalone harness that calls `LapSegmentation.call` on synthetic lap arrays takes about ten lines and needs no Rails — build it, it is the only way to check these claims cheaply.

Definitions of the conventions themselves: [[analytical-conventions]]
