---
name: review-trap-answer-cache-has-no-date
description: Answers::Cache keys on data version plus question text only — no date — so anything date-dependent in a prompt or answer outlives the day it was true
metadata:
  type: reference
---

`app/services/answers/cache.rb` keys chat answers as
`chat:<max(Activity.updated_at, Race.updated_at)>:<sha of normalised question>`.
The standing summary sits under the unversioned key `content` and is only
replaced by the next `RegenerateContentJob`.

**Neither key carries a date.** An answer written on day X is served unchanged
on day X+N for as long as no Activity or Race row is touched — which is exactly
what happens through an injury layoff, a taper, or a travel week.

That was tolerable while cached prose was only *implicitly* dated (tool results
computed at answer time). It gets sharper whenever a change makes the calendar
day an explicit input: a prompt that states today's date, or an instruction that
makes the model print absolute dates, turns silently-stale prose into a visibly
wrong assertion, and can make the *meaning of the question itself* date-dependent
while the cache key stays identical.

**How to apply:** any diff that puts a date, a "today", or a relative-time rule
into `Ai::ChatPrompt` / `Ai::ContentPrompt` must be checked against these two
keys. Ask whether the cached answer is still correct a week later with no
ingestion. If not, the date belongs in `chat_key`. Note that CLAUDE.md's
resolved-decisions table records "answers cache lazily on first ask" keyed on
question text, so changing the key is a decision to surface, not a quiet edit.

Solid Cache eviction is a separate axis — see
[[review-trap-solid-defaults]]. Zone correctness is
[[review-trap-time-and-zone]].
