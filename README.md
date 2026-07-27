# Training Insights

An MCP server for Garmin training data with a single-runner web frontend.

Training Insights exposes a runner's training data as a set of analytical tools accessible via the Model Context Protocol. The MCP server can be connected to any MCP-compatible AI client (Claude Desktop, Claude Code, custom clients) to enable natural conversations grounded in real training data. A Rails web frontend acts as one client among potentially several, providing a public-facing training feed written in third-person voice.

## Why this exists

Most fitness platforms either expose raw data (which AI clients must then aggregate into analytical primitives at runtime) or expose pre-cooked verdicts (which leave nothing for the AI to reason about). Training Insights takes a middle path: an MCP server that returns shaped, aggregated data designed for AI reasoning, with running domain expertise encoded in the tool design rather than in either the raw data or in opinionated conclusions.

The canonical instance runs against Steve Gomori's actual Garmin training data and serves as both the live demonstration and the reference deployment.

## Architecture overview

The MCP server is the primary architectural artifact. The Rails application houses:

- An authenticated webhook endpoint that receives structured activity data from the data pipeline
- A normalized PostgreSQL schema storing activities, computed metrics, and time-series streams
- The MCP server, exposing analytical tools over HTTP/SSE transport
- A web frontend that consumes the MCP server for its AI-powered display
- Pre-generated content cached and regenerated on new activity ingestion

Activity data originates from Garmin FIT files processed by a companion Python project (fit-pipeline), which parses FIT files, computes analytical metrics, and delivers structured JSON to the activity webhook endpoint. Health metrics (sleep, HRV, weight, resting HR) arrive via a separate webhook endpoint, driven by Garmin CSV exports processed through n8n. The Rails app is source-agnostic — it receives and stores structured payloads regardless of where they originated.

The web frontend is one consumer of the MCP server. External MCP clients (Claude Desktop, Claude Code, custom integrations) are first-class peers using the same analytical tool layer.

## Connecting an MCP client

The canonical instance exposes its MCP server publicly with API key authentication. To connect Claude Desktop or another MCP-compatible client:

1. Request an API key (see the live instance for instructions)
2. Add the MCP server to your client configuration with the provided key
3. Ask questions about the runner's training data

A self-hosted deployment can configure its own API keys for distribution.

## Self-hosting

The project is designed to be self-hostable. A self-hoster provides:

- Their own Anthropic API key (for the website's AI features)
- A shared webhook secret (matched to their pipeline instance)
- Runner configuration (name, upcoming races, display preferences)
- Optional API keys for external MCP clients

Data arrives via the companion fit-pipeline project, which handles FIT file parsing and webhook delivery. No third-party API registrations are required — data flows from the runner's own Garmin Connect exports.

Detailed deployment instructions will be added once v1 is complete.

## Project status

Early development. v1 in progress. The repository is currently private and will be made public when the codebase represents the project well.

## Related projects

- [fit-pipeline](link-tbd) — the Python FIT file parser and analytical engine that delivers structured activity data to this application's activity webhook endpoint
- [training-insights-n8n](link-tbd) — n8n workflow definitions for automating pipeline execution and health metric ingestion

## License

To be determined before the repository is made public.
