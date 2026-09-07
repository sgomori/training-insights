---
name: analytical-conventions
description: Durable cross-tool conventions for the MCP aggregation layer — week boundary, small-sample thresholds, tolerance bands, sign conventions, and the deliberate rule inversions — so later aggregations stay mutually consistent.
metadata:
  type: project
---

Conventions every aggregation in `app/mcp/` must agree on. Body re-verified against `main` at a6284f1 plus branch `review-under-fable` on 2026-09-06; the corrections that used to sit in a trailing appendix are now folded into the text.

**Week boundary.** Monday, via `Date#beginning_of_week`, used by `TrainingWindow#weekly_buckets` and `GetPersonalRecords#biggest_period`. `config.beginning_of_week` is *not* set anywhere, so this rests on the Rails default. Every calendar day boundary — including the chat answer cache key — is taken in `Runner.current_time_zone`, never `Date.current`.
**Why:** one definition of week start throughout is what keeps `get_training_load`'s weekly TSS agreeing with `get_race_readiness`'s volume trajectory.
**How to apply:** if anyone sets `config.beginning_of_week`, every weekly bucket in every tool shifts at once and the specs that pin literal week_start dates will catch it — treat that as a deliberate migration, not a config tweak. Never mix a rolling 7-day window with a bucket in the same figure; `TrainingContext` owns rolling windows (acute 7d / chronic 28d), `WeeklyBucket` owns calendar weeks.

**Nil is never zero, and there is no longer an exception.** `WeeklyBucket#daily_tss` materialises a genuine rest day as `0.0` but returns `nil` for a day that was trained and carries no `tss_score`, so callers decide rather than being handed a fabricated zero. Foster's monotony is still defined over the seven days of the week, which is why rest days stay as zeroes.
**How to apply:** treat any other zero-coercion as a bug.

**Small-sample thresholds, and what each actually guards.**
- `TrainingWindow::MIN_SAMPLE_FOR_TREND = 3` — activities per bucket/period. Gates `sufficient_sample` in `get_pace_progression` and delta suppression in `compare_periods`.
- `GetTrainingBlockSummary::MIN_ACTIVITIES_FOR_QUARTILE = 4` — a quartile needs four points.
- `GetTrainingLoad::MIN_WEEKS_FOR_RAMP = 2` — complete weeks, for any week-over-week figure.
- Recovery baselines flag below 7 preceding readings.
- `WeeklyBucket#comparable?` is `complete? && !in_progress?` — the week in progress no longer enters ramp, monotony, strain or taper.
**How to apply:** these gate *inputs*, not the number of points in a least-squares fit. Slopes across buckets and z-scores against a 2-reading baseline are currently ungated — if adding a new trend, decide explicitly which of these it needs and say so on the wire.

**Sign conventions, all confirmed correct.** Pace and grade-adjusted pace are s/km, lower is faster, so a negative delta or slope is an improvement. Efficiency factor and grade-adjusted EF rise with fitness — opposite direction, same response block. Decoupling and monotony: lower is better. `terrain_cost_seconds_per_km = raw − grade_adjusted` is positive because GAP is the flat-*equivalent* pace (confirmed against `../fit-pipeline/docs/middleware.md`), so hills make GAP faster than raw.
**How to apply:** the recurring weakness is not the arithmetic but the prose — a `trend`/`deltas` block that carries pace, EF and decoupling side by side needs per-metric direction from `MetricInterpretation`, not one pace-flavoured sentence.

**Tolerance and reference bands, defined once each.**
- Standard-distance PR bands live in `DistanceBucket::STANDARD` (5k 4.5–5.5, 10k 9–11, half 20–22, marathon 40–44.5 km) and are disclosed on the wire as `tolerance_km`. Descriptive bands are a partition with exclusive upper bounds; standard bands are inclusive at both ends.
- Race-pace work: ±3% of goal pace on grade-adjusted pace. Comparable past race: ±20% of target distance.
- ACWR headroom thresholds 1.3 and 1.5; interpretation bands in `MetricInterpretation[:acute_chronic_ratio]`.
- Steady-state cutoff for cardiac drift and "structured pacing": `pace_cv` 0.20.
**How to apply:** a tolerance that reaches the client must be named in the same response fragment as the figure it produced. Never widen one silently — `DistanceBucket` exists so a "10k" PR and a "10k" pace progression are drawn from the same runs.

**Within-activity (lap) conventions.** A separate namespace from the cross-activity thresholds above — do not conflate them.
- Reference pace for a run's own laps: the **median lap pace**, unweighted by lap distance or duration. Chosen over the mean because short recovery laps sit in the same list.
- Classification band: `max(reference * 0.06, 15 s/km)`. The 15 s/km floor binds below 250 s/km (4:10/km), so it does carry the fast end.
- `MINIMUM_LAPS = 3`, `MINIMUM_REPS = 3` (matches `MIN_SAMPLE_FOR_TREND`), `REP_DISTANCE_RATIO = 1.4` for "these reps are the same effort".
- `recovery?` is any phase that is not `:faster` — a `steady` connector separates two reps, because on an interval session the median lands inside the recovery cluster.
- Auto-lap detection: every lap but the last within 2% of each other, last under 99% of them, **and** the measured figure within 2% of a distance watches actually lap at (`AUTO_LAP_DISTANCES_KM`). Fails closed.
- **Set selection (as of `review-under-fable`).** `longest_alternation` extends one rep at a time from each faster phase and stops at the first rep that breaks `similar_distances?` over the whole accumulated prefix. Because max/min is monotone under extension, that stop is the longest valid window from that start, and the sweep over starts makes the result *exactly* the best contiguous alternating window — brute-force verified, it is not a heuristic. Candidates are ranked `[total rep distance, rep count, earlier start]`.
- Three estimators live in one `repeats` hash and none is named on the wire: `rep_pace_per_km` is distance-weighted, `rep_distance_km` and `recovery_seconds` are medians across reps.
**Why:** a within-run band and a cross-run band answer different questions; a 6% band on one run's laps has nothing to do with the ±3% race-pace band above.
**How to apply:** if a second within-activity tool appears, it must classify against the same median-plus-band or say why not. Whichever estimator a field uses has to be named in the fragment carrying it, same rule as the tolerance bands. And see [[review-standing-concerns]] pattern 9 before adding any new median-over-a-tolerated-set field.

**Foster's monotony uses population SD here** (`MetricMath#standard_deviation`, n not n−1), pinned by spec to 0.87 for daily load 100/0/100/0/100/0/0.
**Why:** the code argues the seven days of a week are the whole population.
**How to apply:** this inflates monotony by sqrt(7/6) ≈ 8% against the published 1.5/2.0 bands, which come from literature computed with sample SD. If the bands or the SD ever change, they have to change together.

**Race projection conventions.**
- The Riegel exponent lives once, in `MetricMath::RIEGEL_EXPONENT = 1.06`, and `riegel_time(seconds, from_km:, to_km:)` is the only implementation. `get_personal_records` and `get_race_projections` rank efforts through the same call, so a "best 10k" agrees between the two tools.
- The reference time basis differs by reference type and is now stated on the wire as `time_basis`. A race projects from nominal distance and recorded elapsed time; a training effort projects from `average_pace_per_km * measured distance`, which the pipeline derives from moving time.
- Projection reliability bands are applied to the **folded** ratio (`ratio >= 1 ? ratio : 1/ratio`), unrounded, so 10k→5k and 5k→10k get the same label. The rounded figure is reported separately.
- Race lookback is a fixed 365 days independent of the `days` parameter, written `today - (RACE_LOOKBACK_DAYS - 1)` — the same half-open-free convention as every other window.
- The then/now fitness comparison is `TrainingContext::CHRONIC_DAYS` (28) on both sides. Equal length by construction, and it overlaps for any race inside ~26 days, which the basis discloses.
- `MetricMath::HARD_ZONE_SHARE_PCT = 20.0` over `zone_4 + zone_5` is the hard/easy split for a whole activity. The zones come from whatever LTHR the FIT file carried that day, which drifts 162-171 bpm across the corpus, so "hard" is not a fixed scale over a 365-day window.
- The "a training projection is a floor" claim is gated on the ratio rather than stated unconditionally.
- **Decoupling changes are percentage *points*; efficiency-factor changes are a *percent change*.** Correct as written — a percent change of a percentage is meaningless — and any new metric pairing has to keep the distinction and name it in the field name.

**Answer cache versioning.** `Answers::Cache.version` is `"#{newest Activity/Race updated_at}:#{Runner.current_time_zone.today}"`. The version is captured in the controller and travels with the job so an answer is filed under the corpus it was computed on. The day component exists because the prompt states today's date.
**How to apply:** anything that caches model prose relative to "today" must key on the runner's day, not the server's, and must use the *captured* day rather than re-deriving it at write time.

Related: [[review-standing-concerns]]
