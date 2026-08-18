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
- The MCP server, exposing analytical tools over Streamable HTTP transport
- A web frontend that reaches the same analytical tools through the Anthropic API's MCP connector, with a chat surface and a standing summary of recent training
- Pre-generated content cached and regenerated on new activity ingestion

Activity data originates from Garmin FIT files processed by a companion Python project (fit-pipeline), which parses FIT files, computes analytical metrics, and delivers structured JSON to the activity webhook endpoint. Health metrics (sleep, HRV, weight, resting HR) arrive via a separate webhook endpoint, driven by Garmin CSV exports processed through n8n. The Rails app is source-agnostic — it receives and stores structured payloads regardless of where they originated.

The web frontend is one consumer of the MCP server. External MCP clients (Claude Desktop, Claude Code, custom integrations) are first-class peers using the same analytical tool layer.

## Connecting an MCP client

The canonical instance exposes its MCP server publicly, authenticated with a static API key presented as a bearer token:

```
Authorization: Bearer <your key>
```

To connect:

1. Request an API key (see the live instance for instructions)
2. Add the MCP server to your client, sending the key in the `Authorization` header
3. Ask questions about the runner's training data

For Claude Code:

```bash
claude mcp add --transport http training-insights https://training.stevegomori.ca/mcp \
  --header "Authorization: Bearer <your key>"
```

Claude Desktop reaches a remote server through a local proxy such as `mcp-remote`, which forwards the same header.

### Which clients this supports

Any client whose configuration lets you set a request header. That covers Claude Code, Claude Desktop via a proxy, and anything speaking Streamable HTTP directly.

It does not cover the custom connectors on claude.ai, which authenticate over OAuth and offer no field for a static token. Supporting them would mean implementing the MCP authorization spec — an OAuth 2.1 authorization server with dynamic client registration — inside an application that is single-runner by design and has no user model to authorize against. That trade is not worth making for one client, so it is deliberately out of scope rather than unbuilt.

A self-hosted deployment issues its own keys, which live in the database rather than in configuration; no redeploy is needed to issue or revoke one.

## Self-hosting

The project is designed to be self-hostable. A self-hoster provides:

- Their own Anthropic API key (for the website's AI features)
- A shared webhook secret (matched to their pipeline instance)
- Runner configuration (name, upcoming races, display preferences)
- Optional API keys for external MCP clients

Data arrives via the companion fit-pipeline project, which handles FIT file parsing and webhook delivery. No third-party API registrations are required — data flows from the runner's own Garmin Connect exports.

A step-by-step self-hosting guide is still to be written. In the meantime, `.env.example` documents every variable a deployment sets, local and production alike, and `render.yaml` shows the canonical deployment those settings came from — one web service plus managed PostgreSQL.

## Local development

Requires Ruby (pinned in `.mise.toml`, installed via [mise](https://mise.jdx.dev)) and PostgreSQL 18.

```bash
mise install
bundle install
bin/rails db:prepare
cp .env.example .env    # then fill in the secrets
bin/rails server
```

Run the quality gate with `bundle exec rubocop`, `bundle exec brakeman`, and `bundle exec rspec`.

### Exercising the MCP server locally

Generate a key, then call the endpoint:

```bash
bin/rails runner 'puts ApiKey.generate!(name: "local-dev")'
```

```bash
curl -s http://localhost:3000/mcp \
  -H "Authorization: Bearer $MCP_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq
```

The transport rejects unrecognised `Host` headers as DNS rebinding protection. Loopback hosts are trusted automatically; any other hostname must be listed in `MCP_ALLOWED_HOSTS`.

### A note on running the chat in development

The website's chat reaches the analytical tools through the Anthropic API's MCP connector, which calls the MCP server over the public internet. That means **chat cannot run against `localhost`**. Two options in development:

- Point `MCP_SERVER_URL` at the deployed instance and use a development API key against it, or
- Expose the local server through a tunnel (`cloudflared tunnel --url http://localhost:3000`) and set `MCP_SERVER_URL` and `MCP_ALLOWED_HOSTS` to the tunnel hostname.

Everything else — ingestion, the MCP server itself, and the tools — runs entirely locally.

Chat answers arrive over Action Cable rather than in the response to the request that asked, so `bin/dev` runs Solid Queue inside Puma: development's cable adapter is process-local, and a job broadcasting from a separate `bin/jobs` would reach nobody.

## Project status

Active and ongoing. The canonical instance runs at [training.stevegomori.ca](https://training.stevegomori.ca) against real Garmin data. The webhook ingestion path, the analytical tool layer, the MCP server, and the web frontend with its chat surface and standing summary are all live.

Work continues. Some v1 deliverables are still outstanding — a TypeScript MCP client example and a self-hosting guide — and health metric ingestion waits on its n8n workflow. Beyond v1, tools get added and existing ones reshaped as questions come up that the current analytical surface answers poorly. The tool inventory and response shapes should be expected to change.

## Related projects

- [fit-pipeline](https://github.com/sgomori/fit-pipeline) — the Python FIT file parser and analytical engine that delivers structured activity data to this application's activity webhook endpoint
- training-insights-n8n — n8n workflow definitions for automating pipeline execution and health metric ingestion. Still in active development and not yet public.

## License

Released under the [MIT License](LICENSE).
