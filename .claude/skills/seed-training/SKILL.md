---
name: seed-training
description: Generate realistic multi-month training data for developing and eyeballing MCP tools. Use when tool development needs data with actual shape to it, before real Garmin history is imported.
---

# Seed training data

MCP tools cannot be judged against three fixture activities. Trends, load ratios, and comparison periods only reveal their bugs over months of data with realistic variation.

## Run it

```bash
cd /home/sgomori/projects/training-insights && bin/rails db:seed
```

Seeds are additive and idempotent on `[source, started_at]` — running twice does not duplicate. To start clean, delete the seeded rows explicitly rather than dropping the database:

```bash
bin/rails runner 'Activity.where(source: "seed").destroy_all'
```

## What the data must look like

Realism matters more than volume, because unrealistic data hides real bugs and invents fake ones.

- **At least 16 weeks**, so a 28-day chronic load window has history behind it and comparison periods have something to compare to.
- **Rest days.** Roughly 4–6 runs a week, not seven. Load math that silently averages over activity count instead of elapsed days only shows up as wrong when rest days exist.
- **A polarized intensity distribution** — mostly easy running, a minority of hard work. Zone distributions should reflect that, and each activity's zone percentages must sum to 100.
- **Varied durations**, from 25-minute recovery jogs to 2-hour long runs. Duration variance is what exposes zone aggregation that averages percentages instead of weighting by time.
- **A build/recover rhythm** — three weeks up, one week down. Without it, acute:chronic ratios sit flat at 1.0 and prove nothing.
- **Slow underlying improvement**: pace drifting down (lower is faster), efficiency factor drifting up, decoupling drifting down. Bury it in noise — a clean monotonic trend will make a broken trend calculation look correct.
- **Some nil computed metrics.** The real pipeline returns `null` when a required stream is missing, and tools must exclude nils rather than zeroing them. If every seeded activity has every metric, that entire bug class stays hidden.
- **A few laps and streams**, not all — both blocks are optional in the real contract.
- **Health metrics** across sleep, hrv, weight, and resting_hr, with gaps. CSV exports are manual and periodic, so gaps are the normal case.
- **At least one upcoming race and one completed race**, so race-readiness tools have something to anchor to.

Use `source: "seed"` so seeded rows are distinguishable from real ingested data at a glance.

## Verify

```bash
bin/rails runner '
  puts "activities:  #{Activity.count} spanning #{Activity.minimum(:started_at)&.to_date} to #{Activity.maximum(:started_at)&.to_date}"
  puts "with nil EF: #{Activity.where(efficiency_factor: nil).count}"
  puts "with laps:   #{Activity.joins(:activity_laps).distinct.count}"
  puts "health:      #{HealthMetric.group(:metric_type).count}"
  puts "races:       #{Race.group(:status).count}"
'
```

## Then

Call the tools against the seeded data and read the responses by eye. This is the step that catches shaping problems no spec will: a load ratio that never moves, a "trend" that reports improvement with the wrong sign, an average dragged down by nils counted as zero.
