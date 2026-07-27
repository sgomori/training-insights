# Training Insights — TypeScript MCP client

A demonstration client showing programmatic access to the Training Insights MCP
server from Node.js using the official MCP TypeScript SDK.

> **Status: not yet implemented.** This directory is scaffolded; the client lands
> in a later branch. The server it will talk to is live — see the curl examples
> below to exercise the same endpoint today.

## What it will demonstrate

- Connecting to the MCP server over Streamable HTTP with API key authentication
- Listing the available tools and their schemas
- Calling a tool and handling the structured response
- A small CLI that takes a question, calls the relevant tools, and prints the result

This is a demonstration artifact rather than production software. A working
connection, a tool listing, and one or two example calls is the whole goal.

## Planned structure

```
examples/typescript-client/
  src/
    index.ts      # CLI entry point
    client.ts     # MCP connection and tool calling
    types.ts      # types for tool responses
  package.json
  tsconfig.json
  README.md
```

## Planned usage

```bash
cd examples/typescript-client
npm install
TRAINING_INSIGHTS_URL=https://training.stevegomori.ca/mcp \
TRAINING_INSIGHTS_API_KEY=your_key \
npm start "How is Steve's training load looking this week?"
```

## Exercising the server in the meantime

The endpoint speaks JSON-RPC over HTTP, so curl is enough to see what the client
will consume.

```bash
# List the available tools
curl -s https://training.stevegomori.ca/mcp \
  -H "Authorization: Bearer $TRAINING_INSIGHTS_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools[].name'
```

```bash
# Call one
curl -s https://training.stevegomori.ca/mcp \
  -H "Authorization: Bearer $TRAINING_INSIGHTS_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call",
       "params":{"name":"get_recent_activity_summary","arguments":{"days":28}}}' \
  | jq '.result.structuredContent'
```

Request an API key from the operator; keys are issued per client and can be
revoked individually.
