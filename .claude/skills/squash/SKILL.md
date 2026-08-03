---
name: squash
description: Squash a feature branch into one clean commit following the project's commit conventions. Use when a branch is ready to merge into main.
---

# Squash a branch

Main's history is one clean commit per merged branch. Branch commits are ephemeral working notes; the squash commit is what gets read later.

## 1. Review what the branch actually did

```bash
git log --oneline main..HEAD
git diff --stat main..HEAD
```

Read the commits and the diff together, then synthesize what *collectively* changed. The squash message describes the end state, not the path taken — do not concatenate the branch commit messages.

## 2. Write the message

Rails community style, per `CLAUDE.md`:

- Imperative mood subject, roughly 50 characters
- No prefix conventions — no `feat:`, `fix:`, `chore:`
- Optional body after a blank line, only when the change genuinely benefits from context
- **No AI co-author trailers. No "Generated with" markers. No emoji.**
- Shorter and more concrete beats longer and more explanatory

```
Add activity webhook receiver

Validates the pipeline payload, writes activities idempotently
on source and started_at, and records every delivery attempt
in webhook_logs.
```

## 3. Squash

```bash
git reset --soft $(git merge-base main HEAD)
git commit -m "Subject line here"
```

`git rebase -i` works equally well if you prefer to edit interactively.

## 4. Verify before merging

```bash
git log -1 --pretty=fuller
```

Confirm the subject reads well in `git log --oneline` and that no trailer snuck in. Then merge to `main`.

Ask before pushing — publishing is a separate decision from committing.
