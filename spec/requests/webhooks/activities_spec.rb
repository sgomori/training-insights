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
        schema_version: "1.1",
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

    # A sensor that drops out mid-run leaves the affected laps without the key
    # at all, since the sender omits nulls. Bulk insert rejects a ragged key
    # set, so the whole activity used to fail on an otherwise ordinary run.
    it "stores laps whose optional fields are present on some laps and absent on others" do
      payload["laps"][1].delete("average_heart_rate")
      payload["laps"][1].delete("average_cadence")
      payload["laps"][2].delete("max_heart_rate")

      expect { post_payload(payload) }.to change(Activity, :count).by(1)
      expect(response).to have_http_status(:ok)

      laps = Activity.sole.activity_laps.order(:lap_index)
      expect(laps.count).to eq(4)
      expect(laps.second.average_heart_rate).to be_nil
      expect(laps.second.average_cadence).to be_nil
      expect(laps.third.max_heart_rate).to be_nil
      expect(laps.first.average_heart_rate).to eq(119)
      expect(laps.second.distance_meters).to be_present
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

    # An unanticipated error used to bypass logging entirely, so the delivery
    # that failed left nothing in webhook_logs and the only evidence was a
    # stack trace in the application log.
    it "logs a delivery that fails for a reason the endpoint did not anticipate" do
      allow(Ingestion::ActivityWriter).to receive(:new).and_raise(ArgumentError, "ragged keys")

      expect { post_payload(payload) }
        .to raise_error(ArgumentError, "ragged keys")
        .and change(WebhookLog, :count).by(1)

      log = WebhookLog.sole
      expect(log).to have_attributes(status: "failed", source_file: "morning_run.fit")
      expect(log.error_message).to eq("ArgumentError: ragged keys")
    end

    it "does not mask the original error when logging the failure also fails" do
      allow(Ingestion::ActivityWriter).to receive(:new).and_raise(ArgumentError, "ragged keys")
      allow(WebhookLog).to receive(:create!).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect { post_payload(payload) }.to raise_error(ArgumentError, "ragged keys")
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

  describe "race linking" do
    let!(:runner) { create(:runner, timezone: "UTC") }

    it "links an activity that lands on a scheduled race day" do
      race = create(:race, race_date: Date.new(2026, 1, 15), distance_meters: 3_200,
        status: "upcoming")

      post_payload(payload)

      expect(Activity.sole.race).to eq(race)
      expect(race.reload).to have_attributes(status: "completed", result_time_seconds: 1_127)
    end

    it "leaves an ordinary training run unlinked" do
      create(:race, race_date: Date.new(2026, 1, 15), distance_meters: 42_195, status: "upcoming")

      post_payload(payload)

      expect(Activity.sole.race).to be_nil
    end

    it "does not relink or duplicate on redelivery" do
      race = create(:race, race_date: Date.new(2026, 1, 15), distance_meters: 3_200,
        status: "upcoming")

      post_payload(payload)
      post_payload(payload)

      expect(Activity.sole.race).to eq(race)
      expect(Activity.races.count).to eq(1)
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

  # The fixture carries 1.1, the version the pipeline emits today. 1.0 differs
  # only in lacking the two local-time fields, so both are accepted.
  describe "schema versions" do
    it "accepts 1.0" do
      payload["schema_version"] = "1.0"
      payload["activity"].delete("started_at_local")
      payload["activity"].delete("utc_offset_seconds")

      expect { post_payload(payload) }.to change(Activity, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(Activity.sole.schema_version).to eq("1.0")
    end

    # 1.1's local-time fields have nowhere to go yet. Discarding them keeps
    # ingestion working across the pipeline deploy; honouring them would mean a
    # migration and a change to how every aggregating tool bounds its days.
    it "accepts the 1.1 local-time fields without storing them" do
      post_payload(payload)

      expect(response).to have_http_status(:ok)
      expect(Activity.sole.started_at).to eq(Time.iso8601("2026-01-15T07:00:00+00:00"))
      expect(Activity.column_names).not_to include("started_at_local", "utc_offset_seconds")
    end

    it "rejects a major version bump" do
      payload["schema_version"] = "2.0"

      expect { post_payload(payload) }.not_to change(Activity, :count)

      expect(response).to have_http_status(:unprocessable_content)
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
