---
name: deploy
description: Deploy the canonical instance to Render and verify the MCP endpoint is live. Use when shipping to training.stevegomori.ca or after changing render.yaml, the Dockerfile, or production configuration.
---

# Deploy to Render

The canonical instance runs on Render: a Starter web service plus a Basic-1gb managed PostgreSQL, defined as code in `render.yaml`.

## Before deploying

```bash
cd /home/sgomori/projects/training-insights
```

Run **/check** and confirm it is fully green. Then verify:

- Every new environment variable is declared in `render.yaml` **and** documented in `.env.example`. A variable that only exists locally is the most common deploy failure here.
- Migrations reverse cleanly (`db:rollback` then `db:migrate`) — Render runs them on deploy and a broken migration takes the service down.
- No secrets are committed. `config/master.key` and `.env` must be gitignored.

## Deploy

Render builds from git. Push the branch and Render picks it up:

```bash
git push origin main
```

Ask before pushing if the user hasn't already asked for a deploy — publishing is a separate decision from committing.

Watch the build in the Render dashboard. The build runs `bundle install`, asset precompilation, and `db:migrate`.

## Verify the deploy

Health first, then the thing that actually matters:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://training.stevegomori.ca/
```

```bash
# MCP tool listing — the endpoint external clients depend on
curl -s https://training.stevegomori.ca/mcp \
  -H "Authorization: Bearer $MCP_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools[].name'
```

```bash
# and confirm auth is actually enforced -> expect 401
curl -s -o /dev/null -w '%{http_code}\n' https://training.stevegomori.ca/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

An unauthenticated `200` here means the server is publicly exposing training data — treat it as an incident, not a bug.

Finally, confirm the webhook receiver is reachable so the pipeline can deliver:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://training.stevegomori.ca/webhooks/activity \
  -H "Authorization: Bearer wrong" -H "Content-Type: application/json" -d '{}'
```

Expect `401` — that proves the route is live and the secret is enforced, without writing anything.

## Operational notes

- **Starter is 512MB.** Puma runs in single mode (`WEB_CONCURRENCY=0`) with Solid Queue embedded via the Puma plugin (`SOLID_QUEUE_IN_PUMA=true`) in **async** mode, so the whole service is one Ruby process. Fork mode ran four more beside it and OOM-restarted the instance at idle on 2026-08-03. Do not raise `WEB_CONCURRENCY` while async mode is set — Puma fires plugins from the cluster master. If the service starts OOM-restarting again, the fix is the Standard tier, not shaving threads.
- **`Ops::MemoryReport` logs RSS and GC statistics hourly.** Grep the Render log stream for `memory rss_mb=` to see the trend before and after a deploy. That is the only memory signal the service emits.
- The MCP transport is mounted **stateless**, so instance count is not a correctness constraint — scaling out is safe.
- Managed PostgreSQL backups are Render's responsibility, but **verify a restore actually works** before treating the canonical instance's data as durable. An untested backup is not a backup.
- The website's chat calls the Anthropic API with the MCP connector pointed at the public `/mcp` URL, so `MCP_SERVER_URL` and `MCP_API_KEY` must be set in the Render environment and the URL must be publicly reachable.
