---
name: analytical-conventions
description: Durable cross-tool conventions for the MCP aggregation layer — week boundary, small-sample thresholds, tolerance bands, sign conventions, and the deliberate rule inversions — so later aggregations stay mutually consistent.
metadata:
  type: project
---

Conventions every aggregation in `app/mcp/` must agree on. Verified against the code on 2026-07-29 (dev branch, tools `get_training_load` through `suggest_next_run`).

**Week boundary.** Monday, via `Date#beginning_of_week`, used by `TrainingWindow#weekly_buckets` and `GetPersonalRecords#biggest_period`. `config.beginning_of_week` is *not* set anywhere, so this rests on the Rails default.
**Why:** one definition of week start throughout is what keeps `get_training_load`'s weekly TSS agreeing with `get_race_readiness`'s volume trajectory.
**How to apply:** if anyone sets `config.beginning_of_week`, every weekly bucket in every tool shifts at once and the specs that pin literal week_start dates will catch it — treat that as a deliberate migration, not a config tweak. Never mix a rolling 7-day window with a bucket in the same figure; `TrainingContext` owns rolling windows (acute 7d / chronic 28d), `WeeklyBucket` owns calendar weeks.

**Deliberate inversions of the project-wide "nil is never zero" rule.** Exactly one exists: `WeeklyBucket#daily_tss` materialises rest days as `0.0` because Foster's monotony is defined over the seven days of the week. It is documented in three places (the plan, the bucket, `monotony_for`).
**Why:** a day with no run genuinely carries no load; an activity whose `tss_score` is nil because a stream was missing does not.
**How to apply:** treat any *other* zero-coercion as a bug. And note `daily_tss` currently uses `tss_score.to_f`, which collapses the very distinction it documents — nil-TSS activities land as rest days.

**Small-sample thresholds, and what each actually guards.**
- `TrainingWindow::MIN_SAMPLE_FOR_TREND = 3` — activities per bucket/period. Gates `sufficient_sample` in `get_pace_progression` and delta suppression in `compare_periods`.
- `GetTrainingBlockSummary::MIN_ACTIVITIES_FOR_QUARTILE = 4` — a quartile needs four points.
- `GetTrainingLoad::MIN_WEEKS_FOR_RAMP = 2` — complete weeks, for any week-over-week figure.
- Recovery baselines flag below 7 preceding readings.
**How to apply:** these gate *inputs*, not the number of points in a least-squares fit. Slopes across buckets and z-scores against a 2-reading baseline are currently ungated — if adding a new trend, decide explicitly which of these it needs and say so on the wire.

**Sign conventions, all confirmed correct as of this review.** Pace and grade-adjusted pace are s/km, lower is faster, so a negative delta or slope is an improvement. Efficiency factor and grade-adjusted EF rise with fitness — opposite direction, same response block. Decoupling and monotony: lower is better. `terrain_cost_seconds_per_km = raw − grade_adjusted` is positive because GAP is the flat-*equivalent* pace (confirmed against `../fit-pipeline/docs/middleware.md`), so hills make GAP faster than raw.
**How to apply:** the recurring weakness is not the arithmetic but the prose — a `trend`/`deltas` block that carries pace, EF and decoupling side by side needs per-metric direction from `MetricInterpretation`, not one pace-flavoured sentence.

**Tolerance and reference bands, defined once each.**
- Standard-distance PR bands live in `DistanceBucket::STANDARD` (5k 4.5–5.5, 10k 9–11, half 20–22, marathon 40–44.5 km) and are disclosed on the wire as `tolerance_km`. Descriptive bands are a partition with exclusive upper bounds; standard bands are inclusive at both ends.
- Race-pace work: ±3% of goal pace on grade-adjusted pace. Comparable past race: ±20% of target distance.
- ACWR headroom thresholds 1.3 and 1.5; interpretation bands in `MetricInterpretation[:acute_chronic_ratio]`.
- Steady-state cutoff for cardiac drift and "structured pacing": `pace_cv` 0.20.
**How to apply:** a tolerance that reaches the client must be named in the same response fragment as the figure it produced. Never widen one silently — `DistanceBucket` exists so a "10k" PR and a "10k" pace progression are drawn from the same runs.

**Within-activity (lap) conventions, added when `LapSegmentation` landed on `chat-surface` 2026-08-04.** These are a separate namespace from the cross-activity thresholds above — do not conflate them.
- Reference pace for a run's own laps: the **median lap pace**, unweighted by lap distance or duration. Chosen over the mean because short recovery laps sit in the same list.
- Classification band: `max(reference * 0.06, 10 s/km)`. The 10 s/km floor is **inert** — it only binds below 166.7 s/km (2:47/km), so the relative term wins at every pace a human runs.
- `MINIMUM_LAPS = 3`, `MINIMUM_REPS = 3` (matches `MIN_SAMPLE_FOR_TREND`), `REP_DISTANCE_RATIO = 1.4` for "these reps are the same effort".
- Auto-lap detection: every lap but the last within 2% of each other, last under 99% of them. No roundness check on the resulting distance, so hand-lapped equal blocks pass.
- Three different estimators live in one `repeats` hash and none is named on the wire: `rep_pace_per_km` is distance-weighted, `rep_distance_km` and `recovery_seconds` are medians across reps.
**Why:** a within-run band and a cross-run band answer different questions; a 6% band on one run's laps has nothing to do with the ±3% race-pace band above.
**How to apply:** if a second within-activity tool appears, it must classify against the same median-plus-band or say why not. Whichever estimator a field uses has to be named in the fragment carrying it, same rule as the tolerance bands.

**Foster's monotony uses population SD here** (`MetricMath#standard_deviation`, n not n−1), pinned by spec to 0.87 for daily load 100/0/100/0/100/0/0.
**Why:** the code argues the seven days of a week are the whole population.
**How to apply:** this inflates monotony by sqrt(7/6) ≈ 8% against the published 1.5/2.0 bands, which come from literature computed with sample SD. If the bands or the SD ever change, they have to change together.

**Race projection conventions, added when `get_race_projections` landed 2026-09-05.**
- The Riegel exponent lives once, in `MetricMath::RIEGEL_EXPONENT = 1.06`, and `riegel_time(seconds, from_km:, to_km:)` is the only implementation. `get_personal_records` and `get_race_projections` rank efforts through the same call, so a "best 10k" agrees between the two tools.
- **The reference time basis differs by reference type and is not stated on the wire.** A race projects from nominal distance and recorded time (elapsed). A training effort projects from `average_pace_per_km * measured distance`, and the pipeline derives `average_pace_per_km` from **moving time** (`fit_pipeline/parser.py` prefers `moving_time_seconds`). Two references in one response are therefore on different clocks.
- Projection reliability bands: far `<0.25`, wide `[0.25,0.5)`, close `[0.5,2.0)`, wide `[2.0,4.0)`, far `>=4.0`, half-open per `MetricInterpretation::Band`. They are **not** symmetric on the log scale the model works on: ratio 0.5 bands "close" and ratio 2.0 bands "wide", so 10k->5k and 5k->10k, and half->marathon and marathon->half, get different labels.
- Race lookback is a fixed 365 days, independent of the `days` parameter, and is written `(today - 365)..today` — 366 inclusive days, where every other window in the codebase uses `today - (days - 1)`.
- The then/now fitness comparison is `TrainingContext::CHRONIC_DAYS` (28) on both sides: `race_date - 28 .. race_date - 1` against `today - 27 .. today`. Equal length by construction, and it overlaps for any race inside ~26 days, which the basis discloses.
- `MetricMath::HARD_ZONE_SHARE_PCT = 20.0` over `zone_4 + zone_5` is the hard/easy split for a whole activity. The zones come from whatever LTHR the FIT file carried that day, which drifts 162-171 bpm across the corpus, so "hard" is not a fixed scale over a 365-day window.
- **Decoupling changes are percentage *points*; efficiency-factor changes are a *percent change*.** Correct as written — a percent change of a percentage is meaningless — and any new metric pairing has to keep the distinction and name it in the field name.

Related: [[review-standing-concerns]]
