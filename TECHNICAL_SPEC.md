# Training Insights — Technical Specification

This document captures the architecture, design decisions, and rationale for Training Insights. It's the primary reference for working in this codebase.

## Project identity

**Name:** Training Insights
**Description:** An MCP server for Garmin training data with a single-runner web frontend.
**Goal:** Portfolio project demonstrating senior-engineering capability through MCP server design, opinionated AI-readable tool architecture, and Rails proficiency. Optionality for product or partnership directions later.
**Canonical runner:** Steve Gomori (single-runner architecture by design)

## Architectural principles

The architecture is shaped by a few decisions that should be preserved across all subsequent design work:

**MCP server is the primary artifact, not the website.** The website is one client of the MCP server. External MCP clients (Claude Desktop, Claude Code, custom integrations) are first-class peers. Code organization, naming, and design decisions should reflect this — the analytical tool layer is the centerpiece.

**Single-runner by design.** No multi-tenancy in v1. The application is configured for one runner per deployment. This is a deliberate scoping choice that lets the analytical tools and data layer go deep without the surface area of multi-tenancy.

**Opinionated data shaping, not verdicts.** MCP tools return curated aggregations that encode running domain expertise as analytical primitives. They do not return raw activity dumps, and they do not return AI-generated narrative or verdicts. The AI client (whatever it is) does the reasoning.

**No AI inside MCP tool execution.** Tools are deterministic. AI calls happen at the client layer (the website's Rails app, or external clients). This preserves the cost model and architectural cleanliness.

**Source-agnostic data layer.** The Rails app knows nothing about FIT files, Garmin, or any specific data source. It receives structured JSON via webhook and stores it in a normalized schema. The pipeline that produces that JSON is a separate concern handled by a separate project.

## Stack

- **Backend:** Ruby on Rails (current stable version), PostgreSQL
- **Frontend:** Hotwire (Turbo + Stimulus), Tailwind CSS
- **No React in v1.** Hotwire handles all client-side interactivity.
- **AI provider:** Anthropic API
- **MCP transport:** HTTP/SSE
- **Background jobs:** Solid Queue (Rails 8 built-in) or Sidekiq, decision deferred to implementation
- **Deployment:** Managed platform — Fly.io preferred, Render as alternative. Research during build.

## Data architecture

### Overview

Training Insights does not connect to any third-party fitness API directly. Activity and health data arrives via authenticated webhook endpoints. The sender of the activity webhook is a separate Python pipeline project (fit-pipeline) that parses Garmin FIT files and computes analytical metrics. The Rails app is agnostic to the sender — any system that can POST a correctly structured JSON payload to the webhook can feed data into the application.

### Data flow

**Activity data (FIT files):**

```
Garmin Connect (web)
  → FIT file download
  → Google Drive drop folder
  → n8n workflow 1 detects .fit file
  → n8n triggers fit-pipeline
  → fit-pipeline parses FIT, computes metrics
  → fit-pipeline POSTs JSON to POST /webhooks/activity
  → Rails validates, normalizes, writes to PostgreSQL
  → MCP tools query PostgreSQL
  → Web frontend and external clients consume MCP tools
```

**Health metrics (sleep, HRV, weight, resting HR):**

```
Garmin Connect (web)
  → CSV export (manual periodic download)
  → Google Drive drop folder
  → n8n workflow 2 detects .csv file
  → n8n parses CSV inline, identifies metric type by filename
  → n8n POSTs normalized JSON to POST /webhooks/health_metric
  → Rails writes to HealthMetric table
```

Both n8n workflows watch the same Google Drive folder, filtered by file type. FIT files go to workflow 1; CSV files go to workflow 2. The two workflows are independent — a failure in one does not affect the other.

Non-trivial logic within n8n workflows (CSV column normalization, metric type detection, error notification formatting) is written in TypeScript using n8n's Code node. This keeps the workflow logic readable, type-safe, and version-controlled alongside the workflow JSON exports.

### Webhook receiver endpoint

The Rails app exposes an authenticated webhook endpoint for activity ingestion:

```
POST /webhooks/activity
Authorization: Bearer <shared_secret>
Content-Type: application/json
```

**Expected payload shape:**

```json
{
  "source": "garmin_fit",
  "file": "2024-03-15-morning-run.fit",
  "processed_at": "2024-03-15T09:23:41Z",
  "activity": {
    "started_at": "2024-03-15T07:00:00Z",
    "type": "run",
    "distance_meters": 15240,
    "duration_seconds": 4823,
    "elevation_gain_meters": 187,
    "average_pace_per_km": 316,
    "average_heart_rate": 148,
    "max_heart_rate": 171,
    "average_cadence": 174,
    "temperature_celsius": 8
  },
  "computed_metrics": {
    "aerobic_decoupling_pct": 3.2,
    "efficiency_factor": 1.48,
    "cardiac_drift_bpm": 11,
    "tss_score": 87,
    "variability_index": 0.04,
    "hr_zone_distribution": {
      "zone_1": 8,
      "zone_2": 34,
      "zone_3": 28,
      "zone_4": 22,
      "zone_5": 8
    },
    "pace_zone_distribution": {
      "easy": 31,
      "moderate": 28,
      "threshold": 26,
      "hard": 15
    }
  },
  "streams": {
    "heart_rate": [134, 136, 138, 141],
    "pace": [320, 318, 315, 312],
    "cadence": [172, 174, 174, 176],
    "altitude": [48.2, 48.4, 48.9, 49.3]
  }
}
```

**Webhook receiver responsibilities:**

- Verify the shared secret in the Authorization header
- Validate the payload structure
- Idempotently write the activity (duplicate detection by started_at + source)
- Write computed metrics to the Activity row
- Write streams to ActivityStream if included in payload
- Log processing result to WebhookLog
- Return 200 on success, 422 on validation failure, 401 on auth failure
- Trigger pre-generated content regeneration after a successful write

**Streams are optional.** The receiver handles payloads with or without the streams key gracefully.

**Authentication:** A shared secret configured as an environment variable on both sides (`WEBHOOK_SECRET`). Simple Bearer token verification. Sufficient for a personal deployment.

### Health metric webhook endpoint

The Rails app exposes a second authenticated webhook endpoint for health metric ingestion:

```
POST /webhooks/health_metric
Authorization: Bearer <shared_secret>
Content-Type: application/json
```

**Expected payload shape:**

```json
{
  "schema_version": "1.0",
  "source": "garmin_csv",
  "metric_type": "sleep",
  "recorded_date": "2024-03-15",
  "processed_at": "2024-03-15T09:00:00Z",
  "values": {
    "sleep_duration_seconds": 27000,
    "sleep_score": 82,
    "deep_sleep_seconds": 5400,
    "light_sleep_seconds": 14400,
    "rem_sleep_seconds": 5400,
    "awake_seconds": 1800
  }
}
```

The `metric_type` field identifies the data type and drives the mapping to HealthMetric columns. Supported types: `sleep`, `hrv`, `weight`, `resting_hr`. n8n determines the type by filename pattern matching (`sleep_*.csv` → `sleep`, `hrv_*.csv` → `hrv`, etc.).

**Health metric webhook receiver responsibilities:**

- Verify the shared secret
- Validate metric_type is a known value
- Idempotently write the record (duplicate detection by recorded_date + metric_type)
- Log processing result to WebhookLog
- Return 200 on success, 422 on validation failure, 401 on auth failure

The health metric webhook uses the same shared secret as the activity webhook. Using separate secrets per endpoint is an option but adds configuration complexity for minimal security benefit in a single-runner personal deployment.

### Data model (initial sketch)

Concrete schema decisions defer to implementation, but the conceptual model:

- **Runner** — singleton for v1. Profile, configuration, current training context (upcoming races, goals).
- **Activity** — a single workout. Source, source_id (for idempotency), type, started_at, distance, duration, summary metrics, and all computed fields (aerobic_decoupling_pct, efficiency_factor, cardiac_drift_bpm, tss_score, variability_index, hr_zone_distribution, pace_zone_distribution).
- **ActivityStream** — time-series data within an activity. Heart rate, pace, cadence, altitude. Populated only when streams are included in the webhook payload. Implementation decision deferred: PostgreSQL array columns on Activity vs. separate timestamped rows.
- **HealthMetric** — daily values for weight, sleep duration, HRV, resting HR. Populated via the `/webhooks/health_metric` endpoint, driven by Garmin CSV exports processed through n8n. In scope for v1.
- **Race** — upcoming and past races. Distance, target time, date, status. Used for race readiness analyses.
- **WebhookLog** — processing log. Timestamp, source file, activity ID created or updated, status, error message if any. Operational visibility without digging through server logs.

The data layer exposes source-agnostic queries to MCP tool implementations. Tools query Activity, ActivityStream, HealthMetric, and Race — never anything source-specific.

### Computed metrics

Computed metrics are derived by the Python pipeline from raw FIT time-series data and stored as first-class fields on the Activity record. The Rails app treats them as ordinary database columns and does not recompute them.

Key computed fields:

- **aerobic_decoupling_pct** — pace:HR ratio drift from first to second half of run. Under 5% indicates good aerobic conditioning. Primary fitness signal for endurance training.
- **efficiency_factor** — normalized pace divided by average HR. Trends upward as fitness improves. Comparable across activities of the same type.
- **cardiac_drift_bpm** — absolute HR rise over a steady-state run. Day-to-day recovery indicator.
- **tss_score** — training stress score equivalent. Duration and intensity-weighted load metric. Feeds training load MCP tools.
- **variability_index** — pace standard deviation. Contextualizes other metrics (track workout vs. trail run).
- **hr_zone_distribution** — time in each HR zone as percentages. Intensity distribution for the activity.
- **pace_zone_distribution** — time in each pace band as percentages.

These fields are what make the MCP tools analytically interesting beyond what summary data alone could support.

### No third-party API dependencies

The Rails application has no Strava OAuth, no Garmin API integration, no external fitness platform credentials. This is deliberate:

- No third-party API terms govern how data is stored or displayed
- No rate limits, no API downtime risk, no credential rotation
- Self-hosters do not need to register API applications with any platform
- Data is owned entirely by the runner who exports and imports it

The tradeoff is that data ingestion is not fully automated — it depends on the runner downloading FIT files from Garmin Connect, dropping them into Google Drive, and having n8n and the Python pipeline handle the rest. For training analysis (patterns over weeks and months) this is acceptable.

## MCP server

### Transport and access

- HTTP/SSE transport
- Publicly accessible endpoint on the canonical instance
- API key authentication: API keys generated and distributed by the operator
- IP-based rate limiting as a baseline against abuse
- Read-only access (no tools that modify data)

### Tool design philosophy

Tools are the central engineering work of this project. The design philosophy:

**Medium-grained, not micro-granular.** Each tool represents a meaningful analytical unit (a training block summary, a pace progression analysis, a race readiness assessment) rather than a raw query primitive. Tools encode domain expertise through their choice of aggregations.

**Opinionated data shaping.** Tools return rich, curated data: aggregations, comparisons, normalized metrics, derived signals. They do not return raw activity lists, and they do not return AI-generated narrative or verdicts. The AI client reasons over the shaped data.

**Composability through escape hatches.** A small number of mid-level query tools provide fallback access for questions the high-level tools don't anticipate. These are escape hatches, not the primary surface.

**No AI in execution.** Every tool is a deterministic function that reads from the database and returns structured data.

**Computed metrics are first-class inputs.** Tools use aerobic_decoupling_pct, efficiency_factor, tss_score, and other computed fields directly from the database without re-deriving them.

### Tool inventory (v1 target)

Five to eight high-level analytical tools, plus two to three mid-level escape hatches. Initial candidates (final shape determined during implementation):

**High-level tools:**

- `get_race_readiness(race_date, race_distance)` — Returns shaped data for assessing readiness: longest runs in relevant periods, weekly volume trajectory, race-pace work, taper status, days to race, aerobic decoupling trend, comparison to past similar buildups.
- `get_training_load(period)` — Returns acute and chronic load metrics derived from tss_score, load ratio, trend, weekly breakdown.
- `get_pace_progression(distance_or_intensity, period)` — Returns pace trend for a specific effort over time, with efficiency_factor trend as a secondary signal.
- `get_training_block_summary(start, end)` — Returns a coherent summary of a training period: volume, intensity distribution from hr_zone_distribution, key workouts, notable aerobic decoupling readings.
- `suggest_next_run(context)` — Returns shaped data informing what a sensible next run would be: recent load, current fatigue indicators, race proximity, recent intensity distribution.
- `get_recent_activity_summary(days)` — Returns the canonical recent-training overview used by the website's pre-generated content.

**Mid-level escape hatches:**

- `get_activities(filters)` — Generic activity fetcher with date, type, and intensity filters.
- `get_personal_records()` — Returns PRs across distances and notable efforts.
- `compare_periods(period_a, period_b, metric)` — Generic comparison primitive.

### Tool response design

Tools return structured JSON that:

- Leads with the most analytically important fields
- Includes enough context for the AI to reason without follow-up tool calls
- Includes comparison points where relevant (vs. last month, vs. same period last year)
- Surfaces anomalies and notable signals explicitly
- Avoids raw activity lists unless that's specifically what the tool exposes

The test for a well-designed tool: can a different reasonable question be answered from this tool's output? If yes, the abstraction is right.

## Web frontend

### Role

The website is one client of the MCP server. Its job is the public-facing display of the runner's training feed, written in third-person voice, with light AI-powered interaction.

Architecturally, the Rails app's controllers act as MCP clients calling the MCP server's tools via the same tool interface available to external clients.

### Page structure

**Primary surface:** Pre-generated content blocks describing the runner's recent training, current training block context, and race readiness if relevant. Written in third-person voice. Generated when a new activity arrives via webhook and cached until the next ingestion.

**Chat surface (below primary content):** A chat input with dynamic suggested prompts based on current configuration — e.g., "Ask about Steve's upcoming 10K race readiness" if a 10K is configured as the next race.

**Transient activity indicators during chat:** Human-readable indicators while tools are being called ("checking recent training data...", "comparing to last training block..."). Do not persist — only the final response remains. Treat as a should-have, not a must-have.

### What is NOT in the web frontend

- No persistent display of tool calls or technical detail
- No explorer view for MCP tool schemas
- No detailed per-activity views with raw data dumps
- No GPS routes or map data (not stored anywhere in the system)
- No embeddable widget for external pages (v1.5+ if at all)

### Privacy

- GPS/route data: not stored anywhere in the system. The webhook payload intentionally excludes GPS coordinates and the schema has no GPS fields.
- Heart rate data: included in MCP responses (analytically useful), not displayed in raw form on the site
- All other activity data: fair game for both display and MCP

## AI integration (website's chat)

The website's chat feature uses the Anthropic API with the MCP server attached as a tool source. Flow:

1. Visitor submits a question
2. Rails app calls Anthropic's API with the question and MCP server tools available
3. Claude decides which tools to call and calls them
4. Claude synthesizes the response
5. Rails app caches the response keyed on the question and returns it to the visitor

### Caching

- Pre-generated content blocks: generated on webhook receipt, cached until next ingestion
- Chat responses: cached on question text, invalidated when new activity data arrives
- One canonical "recent training" pre-generated blurb regenerates after each successful webhook ingestion

### Rate limiting

Per-visitor (IP-based) cap on chat requests. Specific limits set after measuring real per-call API usage during initial development.

The website pays for AI usage (Anthropic API key belongs to the deployment operator). External MCP clients pay for their own AI usage. The MCP server itself uses no AI tokens.

## External MCP client support

The MCP server is publicly accessible at the canonical instance's HTTP/SSE endpoint with API key authentication. Documentation should explain:

- How to obtain an API key
- How to configure Claude Desktop to connect
- What tools are available and what they return
- Rate limits and acceptable use

The goal: a hiring manager or fellow developer can add the canonical instance's MCP server to their Claude Desktop with minimal friction and immediately ask interesting questions about real training data.

### TypeScript MCP client example

The repository includes a TypeScript MCP client example at `examples/typescript-client/`. This demonstrates programmatic access to the MCP server from a TypeScript/Node.js environment using the official MCP TypeScript SDK.

The client shows:

- Connecting to the MCP server with API key authentication
- Listing available tools and their schemas
- Calling specific tools and handling structured responses
- A simple CLI that accepts a natural language question, calls relevant tools, and prints the response

This serves two purposes: it demonstrates the MCP server is a real, usable interface beyond Claude Desktop, and it provides a TypeScript portfolio artifact showing fluency with the MCP protocol in its most common implementation language.

**Structure:**

```
examples/typescript-client/
  src/
    index.ts          # CLI entry point
    client.ts         # MCP connection and tool calling
    types.ts          # TypeScript types for tool responses
  package.json
  tsconfig.json
  README.md           # How to configure and run the client
```

**Usage:**

```bash
cd examples/typescript-client
npm install
TRAINING_INSIGHTS_URL=https://training.stevegomori.ca/mcp \
TRAINING_INSIGHTS_API_KEY=your_key \
npm start "How is Steve's training load looking this week?"
```

The TypeScript client is a demonstration artifact, not production software. It does not need to be feature-complete — a working connection, tool listing, and one or two example tool calls is sufficient to demonstrate the concept.

## Deployment

Target: managed platform. Fly.io preferred for consumption-based pricing, strong Rails community support, and Kamal integration. Render as an alternative if Fly.io proves unsuitable during build.

Requirements:

- Public HTTPS endpoint (needed for webhook receiver and public MCP access)
- Managed PostgreSQL on the same platform
- Background job processing
- Environment variable configuration for API keys and shared secrets
- Reasonable cost for a low-traffic single-instance deployment

Domain: `training.stevegomori.ca`

## Self-hosting model

The project is open source (private repo during initial development, public when the codebase represents the project well).

A self-hoster:

- Forks the repo
- Provisions their own deployment
- Configures their own Anthropic API key
- Sets a shared webhook secret matching their pipeline instance
- Optionally generates API keys for external MCP clients
- Sets up their own instance of fit-pipeline pointed at their webhook URL

No third-party API registrations required.

## Relationship to fit-pipeline

The Python pipeline project (separate repo: fit-pipeline) is the canonical data sender for activity data. It parses Garmin FIT files, computes analytical metrics, and POSTs structured JSON to a configurable webhook URL.

Training Insights treats it as one possible sender. The webhook payload shape and authentication mechanism are the integration contract. Changes to the payload shape are breaking changes and should be handled carefully across both repos.

The fit-pipeline README documents how to configure it to point at a Training Insights deployment. The two projects are developed and versioned independently.

## What's deferred to v1.5 or later

- Embeddable widget for external pages
- Multi-tenant or hosted SaaS version
- Explorer view for MCP tool schemas
- Persistent tool call display in the UI
- React components or any non-Hotwire frontend complexity
- Auto-update notifications for self-hosters
- One-click deployment for non-developer users
- Partnership integrations with fundraising platforms

## Open implementation decisions

To be resolved during build:

- Specific deployment platform (Fly.io vs Render)
- Background job processor (Solid Queue vs Sidekiq)
- Exact MCP server library or implementation approach (existing Ruby MCP libraries vs hand-rolled)
- API key storage and rotation mechanics
- Final tool inventory and exact response schemas
- Specific rate limit thresholds (set after measuring real usage)
- ActivityStream storage (PostgreSQL array columns on Activity vs. separate timestamped table)
