---
name: webhook-replay
description: Replay a real fit-pipeline payload against the local webhook endpoint and verify ingestion and idempotency. Use after changing ingestion code, the activity schema, or the payload contract.
---

# Replay a webhook payload

Exercises the full ingestion path with a payload shaped exactly like what `fit-pipeline` delivers, then proves the write is idempotent.

## 1. Start the app

```bash
cd /home/sgomori/projects/training-insights && bin/rails s
```

`WEBHOOK_SECRET` must be set in the environment the server booted with. Check `.env.example` for the full list.

## 2. Deliver the payload

```bash
curl -s -o /tmp/wh1.json -w '%{http_code}\n' \
  -X POST http://localhost:3000/webhooks/activity \
  -H "Authorization: Bearer $WEBHOOK_SECRET" \
  -H "Content-Type: application/json" \
  -d @spec/fixtures/sample_activity_payload.json
```

Expect `200`.

## 3. Verify what landed

```bash
bin/rails runner '
  a = Activity.order(:started_at).last
  puts "activity:     #{a&.id} #{a&.started_at} #{a&.activity_type}"
  puts "distance:     #{a&.distance_meters} m"
  puts "decoupling:   #{a&.aerobic_decoupling_pct}"
  puts "laps:         #{a&.activity_laps&.count}"
  puts "streams:      #{a&.activity_stream&.heart_rate&.size} hr samples"
  puts "total activities: #{Activity.count}"
  puts "last webhook log: #{WebhookLog.order(:created_at).last&.status}"
'
```

Check that computed metrics are populated (not silently nil), laps arrived, and the stream arrays have the expected length.

## 4. Prove idempotency

Re-POST the identical payload. This is the important assertion — the payload carries no stable source ID, so the uniqueness key is `[source, started_at]`.

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST http://localhost:3000/webhooks/activity \
  -H "Authorization: Bearer $WEBHOOK_SECRET" \
  -H "Content-Type: application/json" \
  -d @spec/fixtures/sample_activity_payload.json
```

Expect `200` again — and `Activity.count` unchanged, with laps and streams **not** duplicated. A second row, or doubled laps, is the bug this step exists to catch.

## 5. Check the failure paths

```bash
# wrong secret -> 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3000/webhooks/activity \
  -H "Authorization: Bearer wrong" -H "Content-Type: application/json" \
  -d @spec/fixtures/sample_activity_payload.json

# malformed body -> 422
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3000/webhooks/activity \
  -H "Authorization: Bearer $WEBHOOK_SECRET" -H "Content-Type: application/json" \
  -d '{"schema_version":"9.9","source":"garmin_fit"}'
```

Every attempt — success or failure — should leave a `WebhookLog` row. That table is the operational visibility the spec asks for; if failures aren't logged, it isn't doing its job.

## Variants worth running

The pipeline omits null fields rather than sending explicit nulls, and three blocks are entirely optional. Strip them and confirm the receiver copes:

```bash
jq 'del(.streams)'           spec/fixtures/sample_activity_payload.json > /tmp/no_streams.json
jq 'del(.laps)'              spec/fixtures/sample_activity_payload.json > /tmp/no_laps.json
jq 'del(.computed_metrics)'  spec/fixtures/sample_activity_payload.json > /tmp/no_metrics.json
```

Each must return `200`.

## Then

Run the **webhook-contract-guardian** subagent to diff the receiver against `../fit-pipeline/docs/payload_schema.md`. A replay proves the code handles *this* fixture; the guardian proves it handles the whole contract.
