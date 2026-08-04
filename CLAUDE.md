# CLAUDE.md

Project-specific conventions for working in the Training Insights codebase.

This file provides guidance to Claude Code when working on this repository. Read it at the start of each session.

## Project overview

Training Insights is an MCP server for Garmin training data with a single-runner Rails web frontend. See `README.md` for the public description, `TECHNICAL_SPEC.md` for architecture details, and `V1_SCOPE.md` for what's in v1 versus what's deferred.

Activity data arrives via an authenticated webhook from the companion `fit-pipeline` project, which parses Garmin FIT files and computes the analytical metrics. Health metrics arrive via a second webhook fed by Garmin CSV exports through n8n. The integration contract is `../fit-pipeline/docs/payload_schema.md` — that document, not the example in `TECHNICAL_SPEC.md`, is authoritative on payload shape.

## Core architectural principles

When making design decisions, preserve these principles:

- **The MCP server is the primary artifact.** The website is one client among potentially several. External MCP clients (Claude Desktop, etc.) are first-class peers, not afterthoughts.
- **Single-runner by design.** No multi-tenancy. Configuration is per-deployment, not per-user.
- **Opinionated data shaping in MCP tools.** Tools return curated aggregations, not raw data and not verdicts. They encode domain expertise through their choice of fields and computations.
- **No AI in MCP tool execution.** Tools are deterministic. AI happens at the client layer.
- **Garmin FIT via webhook is the only ingestion path in v1.** The Rails app integrates with no third-party fitness API — no OAuth, no platform credentials, no rate limits. Design the data layer to be source-agnostic, but don't build other sources. Source-specific knowledge lives in `app/services/ingestion/` and stops there; nothing under `app/models/` or `app/mcp/` may reference Garmin or FIT.

If a proposed change conflicts with any of these, surface the conflict rather than working around it silently.

## Branching and commit workflow

All work happens on feature branches. Main branch history is maintained via squash and merge — each merged branch becomes one clean commit on main.

**Branch commits:** Commit whenever a logical unit of work is complete. Messages should be clear enough to review but don't need to be perfect. These are ephemeral.

**Squash commits:** When instructed to squash a branch, review the branch commits, synthesize what collectively changed, and write one clean commit message following the style guidelines below. Execute via `git rebase -i` or `git reset` + recommit.

## Commit conventions

Commit messages are written in Rails community style:

- Imperative mood subject line, approximately 50 characters
- Optional body separated by a blank line, used when the change benefits from context
- No prefix conventions (no `feat:`, `fix:`, etc.)
- No AI co-author trailers
- No "Generated with Claude Code" or similar markers
- Style should match what an experienced human developer would write

Good examples:

```
Add activity webhook receiver

Validates the pipeline payload, writes activities idempotently
on source and started_at, and records every delivery attempt
in webhook_logs.
```

```
Fix activity sync timing on initial backfill
```

```
Extract pace progression logic into PaceAnalyzer
```

```
Update MCP server to return shaped race readiness data
```

When in doubt, prefer shorter and more concrete over longer and more explanatory.

## Code style

### Ruby and Rails

- Follow standard Rails conventions
- Use Rails idioms (Active Record, Action Controller, etc.) idiomatically
- Prefer service objects or POROs for complex business logic over fat models or fat controllers
- Use Rails 8 features where appropriate (Solid Queue, Solid Cache, etc.)
- Standard Ruby style: 2-space indent, `snake_case` for methods and variables, `CamelCase` for classes

### Frontend

- Hotwire (Turbo + Stimulus) for all client-side interactivity
- Tailwind CSS for styling, using utility classes directly in templates
- No React, Vue, or any other JS framework
- No bespoke build tooling beyond what comes with modern Rails
- Stimulus controllers should be small and focused

### Database

- Migrations should be backward-compatible where possible
- Avoid destructive changes in single migrations (no rename-and-remove in one step)
- Use indexes appropriately, especially on columns used in MCP tool queries
- PostgreSQL-specific features (JSONB, array columns, etc.) are fine to use
- Computed metrics are nullable by design — the pipeline sends `null` when a required stream is missing, and omits null fields from the payload entirely. Aggregations exclude nils; they never coerce them to zero.

## MCP tool design

When implementing or modifying MCP tools, hold these principles:

- **Medium-grained.** Each tool represents a meaningful analytical unit, not a raw query primitive.
- **Opinionated shaping.** Return rich, structured data with aggregations and comparisons. Don't return raw activity lists from analytical tools.
- **Self-contained context.** Include enough information in the response that the AI client can reason without needing follow-up tool calls for basic context.
- **Surface notable signals.** Don't make the AI client compute basic insights; surface them in the response.
- **No AI calls inside tool execution.** Tools are deterministic Ruby code that reads from the database and returns structured data.

Test for a well-designed tool: could a different reasonable question be answered from this tool's output? If yes, the abstraction is right.

## Privacy

Some data is captured but never exposed:

- **GPS coordinates and route data: not stored at all.** The pipeline strips GPS before delivery and the schema has no column to hold it. Never add one — not for a feature, not defensively, not "just in case". The absence of the column is the guarantee; a nullable GPS column would make the promise procedural instead of structural.
- Heart rate data: may be included in MCP responses (it's analytically useful) but should not be displayed in raw form on the website

When in doubt about exposing a field, err toward not exposing.

## Testing

- RSpec for tests, FactoryBot for fixtures
- Test coverage focused on:
  - MCP tool implementations (they're the central engineering work)
  - Ingestion logic (webhook handling, payload validation, idempotency)
  - Data model invariants
  - Background job behavior
- View and integration tests where reasonable but not exhaustive

## Resolved implementation decisions

`TECHNICAL_SPEC.md` left several decisions open. These are now settled — don't re-litigate them without a reason:

| Decision | Choice |
|---|---|
| MCP transport | Streamable HTTP, mounted **stateless**. The HTTP/SSE transport named in the original spec is deprecated. Stateless mode avoids the official SDK's in-memory session state, which would otherwise force a single process. |
| MCP implementation | The official `mcp` Ruby gem, not hand-rolled |
| Background jobs | Solid Queue, embedded in Puma via the plugin, in **async** mode. Fork mode ran a supervisor, dispatcher, worker and scheduler as separate processes, which cost more than a 512MB instance had to give. Async runs them as threads in the web process. The `processes` key in `config/queue.yml` is ignored as a result — scale with threads. |
| ActivityStream storage | PostgreSQL array columns, one row per activity — not timestamped rows. No tool queries *into* a stream; they aggregate whole streams. |
| Activity idempotency key | `[source, started_at]`. The payload carries no stable source ID and `file` can be reused. |
| Deployment | Render — Starter web service plus Basic-1gb managed PostgreSQL. Fly.io was the original preference; its managed Postgres now starts at $38/mo, roughly double the alternative. |
| Website chat → tools | The Anthropic MCP connector pointed at the public `/mcp` URL. Note this means chat cannot run against localhost without a tunnel. |

## Open decisions

Deliberately unresolved. Surface them rather than choosing silently.

| Decision | State |
|---|---|
| Activity type scoping | Every aggregating tool counts all activity types; only `get_activities` filters on one. Invisible on a running-only corpus and silently wrong the first time a ride or a swim is ingested — it will enter volume, load and zone aggregates, and `get_personal_records` will offer a 10km ride as a 10k record. Decide before the first non-run arrives. |
| MCP Resources and Prompts | Both capabilities are advertised and unused. A Resource carrying the methodology behind the metrics, and Prompts for the common questions, would strengthen the demo. Neither is in `V1_SCOPE.md`, so both need a scope decision rather than a quiet addition. |
| `races:sync` on deploy | Not wired into `bin/render-build.sh`, deliberately. Revisit once the race calendar stabilises. |

Two gaps in the source data shape what the tools can currently return. Both
degrade explicitly, and neither is a statement about the runner:

- `pace_zone_distribution` and `rtss_score` are null until the pipeline
  environment carries `THRESHOLD_PACE` and `PACE_ZONE_*`. Until then
  `get_pace_progression`'s intensity mode returns an unavailable block.
- No health metrics exist until the n8n workflow lands, so `suggest_next_run`'s
  recovery block names the metric types it is missing.

## Working with this codebase

- Before adding a feature, check `V1_SCOPE.md` to confirm it's in scope. If it's explicitly out of scope, flag rather than build.
- When in doubt about a design decision, check `TECHNICAL_SPEC.md`. If the spec doesn't address it, surface the decision rather than choosing silently.
- Prefer clarity over cleverness. This is a portfolio project that will be read by hiring managers.
- The codebase should look like work an experienced senior engineer is proud of.

## What not to add

These conventions should be enforced when generating code:

- No AI co-author trailers in commits
- No "Generated with Claude Code" comments in code
- No emoji in code, comments, or commit messages unless specifically requested
- No marketing-style language in docstrings or comments
- No "TODO: improve this" or other vague placeholders — either do it or open an issue
- No leaving debugging output (puts, console.log, byebug) in committed code

## Format preferences

- Markdown files use consistent heading levels and minimal flourishes
- Code comments are sparse and explain "why" rather than "what"
- Method signatures should be self-documenting where possible
