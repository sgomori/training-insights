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
- **MCP transport:** Streamable HTTP (stateless)
- **Background jobs:** Solid Queue (Rails 8 built-in), run inside Puma
- **Deployment:** Render — Starter web service plus managed PostgreSQL

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

> The authoritative contract is [fit-pipeline's `docs/payload_schema.md`](https://github.com/sgomori/fit-pipeline/blob/main/docs/payload_schema.md), which the
> sender is built from. The example below is kept in sync with it; where the two
> disagree, the pipeline's document wins.

```json
{
  "schema_version": "1.1",
  "source": "garmin_fit",
  "file": "morning_run.fit",
  "processed_at": "2024-03-15T09:23:41Z",
  "activity": {
    "started_at": "2024-03-15T07:00:00Z",
    "started_at_local": "2024-03-15T03:00:00",
    "utc_offset_seconds": -14400,
    "type": "running",
    "distance_meters": 15240,
    "duration_seconds": 4823,
    "moving_time_seconds": 4790,
    "elevation_gain_meters": 187,
    "elevation_loss_meters": 174,
    "average_pace_per_km": 316,
    "average_heart_rate": 148,
    "max_heart_rate": 171,
    "average_cadence": 174,
    "max_cadence": 182,
    "average_power": 304,
    "max_power": 395,
    "normalized_power": 306,
    "total_calories": 236,
    "training_stress_score": 87,
    "temperature_celsius": 8
  },
  "computed_metrics": {
    "aerobic_decoupling_pct": 3.2,
    "efficiency_factor": 1.48,
    "cardiac_drift_bpm": 11,
    "tss_score": 87,
    "rtss_score": 91.4,
    "pace_cv": 0.04,
    "trimp": 22.7,
    "avg_grade_adjusted_pace_per_km": 311.4,
    "grade_adjusted_efficiency_factor": 1.51,
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
  "laps": [
    {
      "started_at": "2024-03-15T07:00:00Z",
      "distance_meters": 1000.0,
      "duration_seconds": 316.0,
      "average_heart_rate": 142,
      "max_heart_rate": 151,
      "average_cadence": 172,
      "average_pace_per_km": 316.0
    }
  ],
  "streams": {
    "heart_rate": [134, 136, 138, 141],
    "cadence": [172, 174, 174, 176],
    "enhanced_speed": [3.16, 3.18, 3.21, 3.24],
    "enhanced_altitude": [48.2, 48.4, 48.9, 49.3],
    "power": [271, 288, 297, 301],
    "distance": [0.0, 27.1, 54.9, 82.9],
    "temperature": [8, 8, 8, 9]
  }
}
```

**Two details the receiver must respect:**

- **Null fields are omitted, not sent as explicit nulls.** Absence of a key is
  valid input for anything optional, so validation must not require presence.
- **`activity.training_stress_score` and `computed_metrics.tss_score` are
  different numbers.** The first is the device's own TSS; the second is the
  pipeline's heart-rate-derived TSS. They are stored in separate columns and are
  not interchangeable.

**`laps`, `streams`, and `computed_metrics` are each optional** and any of them
may be absent from an otherwise valid payload.

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

- Streamable HTTP transport, mounted stateless
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
- `describe_run(date)` — Returns one activity's headline figures plus the phases its recorded laps fall into, so an interval session reads as repeats rather than as a single average pace. Laps only; it reads no stream, and it reports the lap basis it worked from because a session lapped every kilometre describes kilometres while one lapped per rep describes reps.

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

### Narrative style: two prompt layers

Tools return numbers; how those numbers get narrated is a client-layer concern. Two separate channels carry it, to two different audiences, and they cannot be merged.

**Server instructions** (`ToolRegistry::INSTRUCTIONS`) reach every client, including external ones, delivered on `initialize`. They carry the reading rules that hold regardless of who is asking, plus a short reporting paragraph. This layer is advisory — an external user's own preferences override it — so it should never carry a constraint the project actually depends on.

**The chat system prompt** applies only to the canonical instance and is binding. Anything the deployment must guarantee belongs here.

The heart rate rule is the clearest case for the split. Heart rate is analytically useful and stays in MCP responses, but must not be displayed in raw form on the site (see Privacy, above). That constraint is real on our surface and meaningless in someone's Claude Desktop, so it can only live in the chat prompt. Unit formatting splits the same way: the wire stays in seconds per kilometre because that is the honest machine representation, and the display rule sits in the client.

The same voice rules apply to pre-generated content blocks, which are third-person prose over the same tools. They are shared between the two rather than written twice, and live in `Ai::Voice`.

### One data path

Chat runs through the Anthropic MCP connector against the public `/mcp` URL, so the model has no database handle and can reach training data only through the tools. There is no shortcut for it to find — only one we could build.

The real exposure is on the generation side, not the chat side. `RegenerateContentJob` already holds an `Activity` when it fires, and the connector needs a public URL so it will not work against localhost. Querying Active Record and passing rows straight to the Anthropic API would be the easy thing to do and would create exactly the second data path the connector decision exists to prevent.

Enforce this structurally rather than by prompt instruction: the chat and content-generation services should have no Active Record dependency at all, asserted in a spec.

### Caching

- Pre-generated content blocks: generated on webhook receipt, cached until next ingestion
- Chat responses: cached on question text, invalidated when new activity data arrives
- One canonical "recent training" pre-generated blurb regenerates after each successful webhook ingestion

### Rate limiting

Per-visitor (IP-based) cap on chat requests. Specific limits set after measuring real per-call API usage during initial development.

The website pays for AI usage (Anthropic API key belongs to the deployment operator). External MCP clients pay for their own AI usage. The MCP server itself uses no AI tokens.

## External MCP client support

The MCP server is publicly accessible at the canonical instance's Streamable HTTP endpoint with API key authentication. Documentation should explain:

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

Target: Render. A Starter web service plus a Basic-1gb managed PostgreSQL, defined as code in `render.yaml`. See "Resolved implementation decisions" below for why this replaced the original Fly.io preference.

Requirements:

- Public HTTPS endpoint (needed for webhook receiver and public MCP access)
- Managed PostgreSQL on the same platform
- Background job processing
- Environment variable configuration for API keys and shared secrets
- Reasonable cost for a low-traffic single-instance deployment

Domain: `training.stevegomori.ca`

## Self-hosting model

The project is open source under the MIT license.

A self-hoster:

- Forks the repo
- Provisions their own deployment
- Configures their own Anthropic API key
- Sets a shared webhook secret matching their pipeline instance
- Optionally generates API keys for external MCP clients
- Sets up their own instance of fit-pipeline pointed at their webhook URL

No third-party API registrations required.

## Relationship to fit-pipeline

The Python pipeline project ([separate repo](https://github.com/sgomori/fit-pipeline)) is the canonical data sender for activity data. It parses Garmin FIT files, computes analytical metrics, and POSTs structured JSON to a configurable webhook URL.

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

## Resolved implementation decisions

Settled during the initial build:

- **Deployment platform: Render.** A Starter web service plus a Basic-1gb managed PostgreSQL, defined as code in `render.yaml`, at roughly $26/month. Fly.io was the original preference on consumption pricing, but its Managed Postgres now starts at $38/month with no smaller tier, putting an equivalent Fly stack near $47/month. The legacy unmanaged `fly pg` is cheaper but deprecated and explicitly not a managed service.
- **Background jobs: Solid Queue**, run inside Puma via the plugin. One instance serves web and jobs, which fits the Starter tier and the traffic profile.
- **MCP implementation: the official `mcp` Ruby gem** (1.0.0), not hand-rolled.
- **MCP transport: Streamable HTTP, mounted stateless.** HTTP/SSE, named earlier in this document, has been deprecated in the protocol. Stateless mode matters beyond protocol currency: the transport's stateful mode holds session and SSE state in process memory, which would make correctness depend on running exactly one process. Every tool is read-only, so there is no session worth keeping.
- **ActivityStream storage: PostgreSQL array columns**, one row per activity. No tool queries *into* a stream — they aggregate whole streams — so per-sample rows would add hundreds of thousands of rows for no analytical gain.
- **Activity idempotency key: `[source, started_at]`.** The payload carries no stable source identifier and `file` can be reused.
- **API key storage: SHA-256 digests only.** A key is displayed once at generation and cannot be recovered; rotation is reissue-and-revoke.
- **Website chat reaches the tools through the Anthropic MCP connector** pointed at the public `/mcp` URL, rather than the Rails app calling its own tools in process. This dogfoods the public interface, and means chat cannot run against localhost without a tunnel.

Still open:

- Final tool inventory and exact response schemas
- Specific rate limit thresholds — the placeholders in `config/initializers/rack_attack.rb` stand in until real per-call usage can be measured on the canonical instance
