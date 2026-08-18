# Training Insights — v1 Scope

This document defines what's in v1, what's deferred, and the explicit non-goals. Its job is to prevent scope creep during the build.

## The three things v1 must deliver

1. **An MCP server with well-designed analytical tools.** The central engineering work. 5-8 high-level tools with opinionated data shaping, plus 2-3 mid-level escape hatches. Seven high-level tools and three escape hatches shipped. The tool design encodes running domain expertise and is the project's primary differentiator.

2. **The canonical instance running publicly with real training data.** Deployed to `training.stevegomori.ca`, populated with historical activity data from Garmin FIT files, displaying pre-generated content and supporting chat interactions.

3. **One demonstration that makes the MCP server's value visible to someone who won't install it.** Specifically: shared Claude conversation links accessible from the canonical instance, showing real interactions with the runner's training data via the MCP server.

If v1 ships with these three things working well, it's a success.

## In scope for v1

### Backend

- Rails 8 application with PostgreSQL
- Authenticated webhook endpoint (`POST /webhooks/activity`) for receiving activity data from the pipeline
- Payload validation, idempotent writes, and processing log
- Normalized data model for activities, computed metrics, streams, and runner configuration
- Pre-generated content regeneration triggered by successful webhook ingestion
- Background job processing for content generation and caching

### MCP server

- Streamable HTTP transport (stateless)
- API key authentication
- IP-based rate limiting
- Tool implementations for the v1 inventory:
  - `get_race_readiness`
  - `get_training_load`
  - `get_pace_progression`
  - `get_training_block_summary`
  - `suggest_next_run`
  - `get_recent_activity_summary`
  - `describe_run`
  - `get_activities` (escape hatch)
  - `get_personal_records` (escape hatch)
  - `compare_periods` (escape hatch)
- Tool response schemas with opinionated data shaping
- Documentation for connecting external MCP clients

### Web frontend

- Pre-generated content block displaying recent training in third-person voice
- Chat interface with dynamic suggested prompts based on current race configuration
- Transient activity indicators during chat processing (should-have)
- Rate limiting on chat per visitor IP
- Clean, minimal visual design — Hotwire-driven, Tailwind-styled

### AI integration

- Anthropic API integration for website chat and pre-generated content
- Caching layer for pre-generated content (regenerates on new activity ingestion)
- Caching layer for chat responses (keyed on question, invalidated on new activity)
- Per-visitor rate limits

### Health metric ingestion

- Authenticated webhook endpoint (`POST /webhooks/health_metric`) receiving CSV-derived health data from n8n
- Support for metric types: sleep, hrv, weight, resting_hr
- Idempotent writes keyed on recorded_date + metric_type
- WebhookLog entries for health metric ingestion

### TypeScript MCP client example

- `examples/typescript-client/` demonstrating programmatic MCP server access
- TypeScript/Node.js using the official MCP TypeScript SDK
- CLI that accepts a question, calls relevant tools, prints response
- Working connection, tool listing, and example tool calls
- Own README with setup and configuration instructions

### Operations

- Deployment to `training.stevegomori.ca` on Render (Starter web service plus managed PostgreSQL)
- Public HTTPS endpoint for webhook receiver and MCP access
- Basic operational documentation in the repo
- WebhookLog table for ingestion observability

### Documentation

- README explaining what the project is, how it works, and how to connect an MCP client
- CLAUDE.md for project-specific conventions
- TECHNICAL_SPEC.md as the architecture reference
- Self-hosting guide including how to configure the companion fit-pipeline project

## Explicitly out of scope for v1

These are deferred to v1.5 or later and should not be added even if they seem like small additions:

- Embeddable widget for external pages
- Multi-tenant or hosted SaaS version
- Garmin, Strava, or any direct third-party API integration
- React components or any non-Hotwire frontend
- Explorer view for MCP tool schemas
- Persistent tool call display in the UI (transient activity indicators are the v1 compromise)
- Auto-update notifications for self-hosters
- One-click deployment for non-developer users
- Partnership integrations with fundraising platforms
- Detailed per-activity views with stream visualizations
- GPS or route display anywhere (GPS data is excluded from the system entirely)
- User authentication for the web frontend (fully public, read-only)
- Admin UI beyond minimum configuration management
- Email, newsletter, or RSS features

## Non-goals

- **Not a Garmin or Strava replacement.** The web frontend does not try to replicate any fitness platform's dashboard. It does what those platforms don't: opinionated AI-readable analytical tools.
- **Not a multi-user platform.** Each deployment is one runner. No signup flow, no account management.
- **Not a coaching service.** Tools return shaped analytical data. They do not prescribe training.
- **Not real-time.** Data arrives when the runner downloads and imports FIT files. Sub-minute latency is not a goal.

## Build approach

The work is being done with Claude Code assistance. Steve will review code and may write portions himself as a Rails familiarity exercise.

There is no hard timeline. The expectation is that this is the immediate priority and will be built as quickly as it can be built well.

## Repository visibility

The repository is private during initial development. It will be made public when Steve wants to reference it in a job application — that's the trigger, whatever state the project is in at that point.

## When v1 is "done"

V1 is done when:

- The canonical instance is live at `training.stevegomori.ca` with real Garmin activity data
- All v1 tools are implemented and return reasonable shaped data
- An external MCP client (e.g., Claude Desktop) can connect and successfully query the canonical instance
- The website displays pre-generated content and supports working chat
- At least one shared Claude conversation link demonstrates the MCP server in action
- The webhook receiver successfully accepts payloads from the Python pipeline
- The README, TECHNICAL_SPEC, and CLAUDE.md are accurate and current

No specific date. The bar is quality, not speed.
