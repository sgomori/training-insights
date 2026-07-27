---
name: new-mcp-tool
description: Scaffold a new MCP analytical tool with its registry entry, spec, and documentation. Use when adding a tool to the v1 inventory or designing a new analytical unit.
---

# Add an MCP tool

Tools are the central engineering work of this project. Design the response shape *before* writing the query — the shape is the deliverable, the SQL is an implementation detail.

## 1. Confirm it belongs

Check `V1_SCOPE.md` for the target inventory. The v1 high-level tools are `get_race_readiness`, `get_training_load`, `get_pace_progression`, `get_training_block_summary`, `suggest_next_run`, `get_recent_activity_summary`; the escape hatches are `get_activities`, `get_personal_records`, `compare_periods`. A tool outside that list needs a scope decision first — surface it rather than building it.

## 2. Design the response shape first

Write the JSON you want the tool to return, with realistic numbers, before any code. Then check it against the spec's own test:

> **Could a different reasonable question be answered from this output?**

If no, the abstraction is too narrow. Also confirm it: leads with the most analytically important fields; states units and the period covered; includes a comparison point where one is meaningful; surfaces notable signals as explicit fields rather than leaving them to be derived; and contains no verdicts, ratings, or narrative — the AI client reasons, the tool shapes.

## 3. Write the tool

`app/mcp/tools/<tool_name>.rb`, subclassing the base tool. Deterministic Ruby only — database reads and arithmetic. No network calls, no `Anthropic::`, no AI of any kind inside `app/mcp/`.

Handle the thin-data cases explicitly: no activities in the period, a single activity, and computed metrics that are `nil` because the pipeline lacked a required stream. Nils are excluded from aggregates, never coerced to zero.

## 4. Register it

Add the class to `app/mcp/registry.rb`. That file is the single source of truth for what the server exposes — a tool that isn't listed doesn't exist.

## 5. Spec it

`spec/mcp/tools/<tool_name>_spec.rb`. Cover the happy path, the empty-data case, the single-activity case, and nil-metric handling. Assert on the response *shape*, not just values — the field names are a public contract that external MCP clients depend on.

## 6. Verify end to end

```bash
bin/rails s
```

```bash
curl -s http://localhost:3000/mcp \
  -H "Authorization: Bearer $MCP_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools[].name'
```

Then call it with `tools/call` and read the actual output. Judge the shape by eye — this is the step that catches a tool that passes its specs but returns something no AI client can reason over.

## 7. Then

Run **/check**, then the **mcp-tool-reviewer** subagent. If the tool computes trends, load ratios, or zone aggregates, also run **running-analytics-reviewer** — sign errors and unweighted zone averages are invisible to tests.
