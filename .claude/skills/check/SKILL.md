---
name: check
description: Run the full quality gate — linter, security scanner, and test suite — and report results honestly. Use before committing, after editing code, or whenever the user wants to confirm the project is green.
---

# Quality gate

Run all three. Report pass/fail counts plainly — never suppress, skip, or soften a failure.

```bash
cd /home/sgomori/projects/training-insights && \
  bundle exec rubocop && \
  bundle exec brakeman -q --no-pager && \
  bundle exec rspec
```

Run them individually if you need to isolate a failure. If a tool is missing, `bundle install` first; if the database refuses connections, check `pg_isready` before blaming the code (the fix is `sudo service postgresql start`, which needs a password you don't have — report it rather than attempting it).

For a long suite, delegate to the **rails-runner** subagent so the output stays out of the main context.

## After running

- Report the outcome exactly: "rubocop clean, brakeman clean, 47/47 examples passed" — or the verbatim failure text and counts.
- If specs fail, find the root cause. Never mark a spec pending or loosen an assertion to get green.
- If Brakeman raises a warning you believe is a false positive, say why explicitly rather than silently adding it to the ignore file.

## Then

Route to the reviewer that matches what changed — lint and tests catch none of what these look for:

| Changed | Reviewer |
|---|---|
| anything under `app/mcp/` | **mcp-tool-reviewer** |
| aggregation or trend math | **running-analytics-reviewer** |
| `app/services/ingestion/`, webhook controllers, activity schema | **webhook-contract-guardian** |
| anything else non-trivial | **rails-reviewer** |
