---
name: reference-docs-that-drift
description: Untracked and out-of-diff documents that go stale on infrastructure changes — PHASE_3_PLAN.md and .claude/skills/deploy/SKILL.md
metadata:
  type: reference
---

Two documents carry deployment/capacity rationale but will not show up in a
`git diff` review of an infrastructure change:

- `PHASE_3_PLAN.md` (repo root) is deliberately excluded via `.git/info/exclude`
  ("Working plan for Phase 3, untracked and removed when the work lands"). It is
  never in `git status` or `git diff`, so read it directly when a change touches
  capacity, queue topology, or the chat work. Do not report it as "missing from
  the diff" — that is by design.
- `.claude/skills/deploy/SKILL.md` is the operational runbook a future session
  reads while deploying. Its "Operational notes" section restates the Puma /
  Solid Queue / memory story, so any change to `config/puma.rb`, `render.yaml`,
  or `config/database.yml` pool sizing should be checked against it for stale
  claims.

**How to apply:** on any diff touching `config/puma.rb`, `config/queue.yml`,
`config/database.yml`, or `render.yaml`, open both files and flag contradictions
as findings rather than assuming the tracked docs (`CLAUDE.md`,
`TECHNICAL_SPEC.md`) are the whole documentation surface.
