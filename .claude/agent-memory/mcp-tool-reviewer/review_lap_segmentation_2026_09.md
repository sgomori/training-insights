---
name: review-lap-segmentation-2026-09
description: Findings on the rep-by-rep set walk in LapSegmentation.longest_alternation and the pronoun guard, branch review-under-fable, 2026-09-06, report-only and left unfixed
metadata:
  type: project
---

Reviewed the `app/mcp/` half of branch `review-under-fable` on 2026-09-06
(commits db99cff "Judge a set of repeats as it is walked" and 1bcc6cc "Stop
assuming the runner's pronoun"). Report-only by instruction, so everything below
was **raised and left open**.

What changed: `longest_alternation` now grows a rep set one rep at a time and
stops at the first rep whose distance is not similar to those gathered, instead
of taking the whole alternation and applying `similar_distances?` to it.
`describe_run`'s drift clause says "The reps held within" instead of "He held
them", and `spec/mcp/client_visible_language_spec.rb` gained a `PRONOUN` guard.

Two facts about the algorithm worth keeping, both established by probing old
against new on eight session shapes:

- The new walk **can never find fewer reps than the old one**. `max/min <= 1.4`
  is monotone under right-extension, so the greedy prefix from each start is the
  longest valid window from that start, and the global max over starts is exact.
  The old code only ever considered *suffixes* of an alternation, because
  `finish` always ran to the end of it.
- The regression is therefore never "loses a set", only "picks the wrong one".

Ranked as reported:

1. **Count-only ranking now prefers a numerous short set over the main work.**
   Because every contiguous window competes now rather than only suffixes, a
   leading set of strides can win on rep count. Probed: warmup, 4x200m strides,
   3x1600m — old reported `3 x 1.6 km`, new reports `4 x 0.2 km` and leaves the
   1600s as loose `faster` phases. Suggested rank: total rep distance or total
   rep duration, with count as tiebreak and earlier start last.
2. **The demoted second set is invisible in `notable`.** `DescribeRun.
   sustained_effort_signal` early-returns whenever a repeats phase exists, so
   the case above narrates "4 repetitions of about 0.2 km" and never mentions
   9 km of tempo the `structure` block does carry.
3. **Ladders now resolve by direction, not by size.** "Ties go to the earlier
   set" fixes the descending ladder (4x1000 then 4x400 now reports the 1000s,
   correctly) and breaks the ascending one (4x400 then 4x1000 now reports the
   400s where the old code reported the 1000s). Same fix as finding 1.
4. `absorbable_tail?` can now swallow the **transition between two sets**, since
   `last` is no longer the end of the alternation. Bounded at 2x the median
   established recovery, so never egregious.
5. The pronoun guard's reach: `prose_lines` only inspects lines containing a
   `"`, and `PROSE_FILES` is hand-maintained — `app/mcp/distance_bucket.rb`
   carries client-visible labels and is not listed.

Assessed as **worth reusing**: the greedy-with-monotone-predicate walk is the
right shape and is exact for its objective; the comment argues the change from
the session that broke rather than from the rule; the spec covers both the
motivating case and both ladder directions; and the `PRONOUN` guard makes an
architectural fact (the server has no runner pronoun, names are configuration)
enforceable rather than a convention.

**Why:** report-only by instruction, and finding 1 changes which set a client is
told the workout was, which is the tool's headline claim.

**How to apply:** if asked to review `LapSegmentation` again, check these five
first and say which are fixed rather than re-deriving them. The probe harness
pattern — load the pre-merge-base file under a renamed module beside the new one
and diff their phase output over a table of session shapes — is what made
findings 1 and 3 visible; nothing in the spec suite catches them.

Related: [[review-describe-run-2026-08]], [[review-describe-run-anchors-2026-09]],
[[conventions-tool-shaping]]
