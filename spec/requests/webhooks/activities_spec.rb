require "rails_helper"

RSpec.describe "POST /webhooks/activity" do
  let(:secret) { "test-webhook-secret" }
  let(:payload) { JSON.parse(file_fixture("sample_activity_payload.json").read) }

  def post_payload(body, token: secret)
    post "/webhooks/activity",
      params: body.to_json,
      headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
  end

  around do |example|
    original = ENV["WEBHOOK_SECRET"]
    ENV["WEBHOOK_SECRET"] = secret
    example.run
    ENV["WEBHOOK_SECRET"] = original
  end

  describe "authentication" do
    it "rejects a wrong secret without writing anything" do
      expect { post_payload(payload, token: "wrong") }.not_to change(Activity, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a missing Authorization header" do
      post "/webhooks/activity", params: payload.to_json,
        headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects every request when no secret is configured" do
      ENV["WEBHOOK_SECRET"] = nil

      post_payload(payload, token: "")

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "a valid payload" do
    it "returns 200 and creates the activity" do
      expect { post_payload(payload) }.to change(Activity, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("created")
    end

    it "stores the envelope and summary fields" do
      post_payload(payload)
      activity = Activity.sole

      expect(activity).to have_attributes(
        source: "garmin_fit",
        source_file: "morning_run.fit",
        schema_version: "1.0",
        activity_type: "running",
        distance_meters: 3156.5,
        average_heart_rate: 130,
        normalized_power: 306
      )
      expect(activity.started_at).to eq(Time.iso8601("2026-01-15T07:00:00+00:00"))
    end

    it "stores every computed metric the pipeline sends" do
      post_payload(payload)
      activity = Activity.sole

      expect(activity).to have_attributes(
        aerobic_decoupling_pct: 7.88,
        efficiency_factor: 1.288,
        cardiac_drift_bpm: 21,
        tss_score: 19.0,
        rtss_score: 22.9,
        pace_cv: 0.0917,
        trimp: 22.7,
        avg_grade_adjusted_pace_per_km: 351.1,
        grade_adjusted_efficiency_factor: 1.3147
      )
      expect(activity.hr_zone_distribution).to eq("zone_1" => 100.0, "zone_2" => 0.0,
        "zone_3" => 0.0, "zone_4" => 0.0, "zone_5" => 0.0)
      expect(activity.pace_zone_distribution["easy"]).to eq(41.8)
    end

    it "keeps device TSS separate from the pipeline's computed tss_score" do
      payload["activity"]["training_stress_score"] = 87.0
      post_payload(payload)

      activity = Activity.sole
      expect(activity.device_training_stress_score).to eq(87.0)
      expect(activity.tss_score).to eq(19.0)
    end

    it "stores laps in payload order" do
      post_payload(payload)
      laps = Activity.sole.activity_laps

      expect(laps.count).to eq(4)
      expect(laps.map(&:lap_index)).to eq([ 0, 1, 2, 3 ])
      expect(laps.first.average_heart_rate).to eq(119)
      expect(laps.last.distance_meters).to eq(156.5)
    end

    it "stores streams under the enhanced_ keys the pipeline actually sends" do
      post_payload(payload)
      stream = Activity.sole.activity_stream

      expect(stream.heart_rate.first).to eq(112)
      expect(stream.enhanced_speed.first).to eq(2.6)
      expect(stream.enhanced_altitude.first).to eq(48.2)
      expect(stream.available_streams).to contain_exactly(
        :heart_rate, :cadence, :enhanced_speed, :enhanced_altitude,
        :power, :distance, :temperature
      )
    end

    it "enqueues content regeneration" do
      expect { post_payload(payload) }
        .to have_enqueued_job(RegenerateContentJob)
    end

    it "logs the delivery" do
      expect { post_payload(payload) }.to change(WebhookLog, :count).by(1)

      log = WebhookLog.sole
      expect(log).to have_attributes(
        endpoint: "/webhooks/activity",
        status: "created",
        source_file: "morning_run.fit"
      )
      expect(log.record).to eq(Activity.sole)
    end
  end

  describe "optional blocks the sender may omit" do
    it "accepts a payload with no streams" do
      payload.delete("streams")

      expect { post_payload(payload) }.to change(Activity, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(Activity.sole.activity_stream).to be_nil
    end

    it "accepts a payload with no laps" do
      payload.delete("laps")

      expect { post_payload(payload) }.to change(Activity, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(Activity.sole.activity_laps).to be_empty
    end

    it "accepts a payload with no computed_metrics" do
      payload.delete("computed_metrics")

      expect { post_payload(payload) }.to change(Activity, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(Activity.sole.tss_score).to be_nil
    end

    it "accepts omitted optional summary fields rather than requiring explicit nulls" do
      payload["activity"].delete("average_power")
      payload["activity"].delete("total_calories")

      post_payload(payload)

      expect(response).to have_http_status(:ok)
      expect(Activity.sole.average_power).to be_nil
    end
  end

  describe "idempotency" do
    it "does not create a second activity for a redelivered payload" do
      post_payload(payload)
      expect { post_payload(payload) }.not_to change(Activity, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("updated")
    end

    it "does not duplicate laps or streams on redelivery" do
      post_payload(payload)
      post_payload(payload)

      activity = Activity.sole
      expect(activity.activity_laps.count).to eq(4)
      expect(ActivityStream.count).to eq(1)
      expect(activity.activity_stream.heart_rate.size).to eq(11)
    end

    it "applies corrected values from a redelivered payload" do
      post_payload(payload)
      payload["computed_metrics"]["tss_score"] = 42.0
      post_payload(payload)

      expect(Activity.sole.tss_score).to eq(42.0)
    end

    it "treats the same start time from a different source as a distinct activity" do
      post_payload(payload)
      payload["source"] = "other_pipeline"

      expect { post_payload(payload) }.to change(Activity, :count).by(1)
    end
  end

  describe "invalid payloads" do
    it "rejects an unknown schema_version rather than parsing optimistically" do
      payload["schema_version"] = "9.9"

      expect { post_payload(payload) }.not_to change(Activity, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"].first).to match(/unsupported schema_version/)
    end

    it "rejects a missing schema_version" do
      payload.delete("schema_version")
      post_payload(payload)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a payload with no activity block" do
      payload.delete("activity")
      post_payload(payload)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("activity is required")
    end

    it "rejects a missing started_at" do
      payload["activity"].delete("started_at")
      post_payload(payload)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("activity.started_at is required")
    end

    it "rejects an unparseable started_at" do
      payload["activity"]["started_at"] = "not-a-timestamp"
      post_payload(payload)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"].first).to match(/ISO 8601/)
    end

    it "rejects a malformed JSON body" do
      post "/webhooks/activity", params: "{not json",
        headers: { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("request body must be a JSON object")
    end

    it "rejects a JSON body that is not an object" do
      post "/webhooks/activity", params: "[1, 2, 3]",
        headers: { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "logs rejected deliveries" do
      payload["schema_version"] = "9.9"

      expect { post_payload(payload) }.to change(WebhookLog, :count).by(1)

      expect(WebhookLog.sole).to have_attributes(status: "rejected")
      expect(WebhookLog.sole.error_message).to match(/unsupported schema_version/)
    end
  end
end
