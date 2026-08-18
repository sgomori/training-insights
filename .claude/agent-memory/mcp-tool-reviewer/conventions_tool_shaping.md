---
name: conventions-tool-shaping
description: Non-obvious shaping conventions in the MCP tool layer that look like bugs on inspection but are deliberate — check before flagging them again
metadata:
  type: project
---

Five things in `app/mcp/` read like defects but are deliberate and documented at
the call site. Do not re-flag them.

1. **Rest days count as zero in Foster's monotony only.** `TrainingWindow::WeeklyBucket#daily_tss`
   introduces the zeros; `GetTrainingLoad.monotony_for` consumes them. This
   inverts the project-wide "a nil is never a zero" rule on purpose — a day with
   no run genuinely carries no load, unlike an activity whose `tss_score` is nil
   because a stream was missing.
2. **Races are excluded from aerobic averages and from pace deltas, and nowhere else.**
   They count fully in volume, terrain, load and intensity distribution. Every
   affected block carries a `basis` string saying so.
3. **A thin delta is suppressed with a named reason, not returned as null.**
   `compare_periods` collects these into a `suppressed` block; the threshold is
   `TrainingWindow::MIN_SAMPLE_FOR_TREND` (3).
4. **Buckets below the sample threshold are emitted flagged, not dropped**, so a
   gap in training stays visible in a series.
5. **A nil metric is emitted as an explicit `null`, not compacted away.** The
   missing `.compact` on `MetricInterpretation.describe`'s `value` key looks like
   an oversight and is argued out in the comment above it; the per-activity
   blocks (`GetActivities#present`, `GetTrainingBlockSummary#summarise`) follow
   the same rule. Only the *descriptive* keys — band, caveats, sample_size —
   compact away. Reason: an absent key leaves a client unable to tell a missing
   measurement from a misremembered field name. A new per-activity block that
   ends `.compact` is a finding, not a style choice.

**Why:** each inverts or bends a general rule, so a reviewer reading only the
general rule will read them as bugs and a future author may "fix" them.

**How to apply:** when reviewing a diff that touches nil handling, race scoping
or sample guards in `app/mcp/`, check it against these four before writing a
finding. A new tool that departs from them without a comment at the call site
*is* a finding.

Related: [[review-tool-layer-2026-07]]
