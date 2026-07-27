require "rails_helper"

RSpec.describe "POST /webhooks/health_metric" do
  let(:secret) { "test-webhook-secret" }
  let(:payload) do
    {
      "schema_version" => "1.0",
      "source" => "garmin_csv",
      "metric_type" => "sleep",
      "recorded_date" => "2026-03-15",
      "processed_at" => "2026-03-15T09:00:00Z",
      "values" => {
        "sleep_duration_seconds" => 27_000,
        "sleep_score" => 82,
        "deep_sleep_seconds" => 5_400,
        "light_sleep_seconds" => 14_400,
        "rem_sleep_seconds" => 5_400,
        "awake_seconds" => 1_800
      }
    }
  end

  def post_payload(body, token: secret)
    post "/webhooks/health_metric",
      params: body.to_json,
      headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
  end

  around do |example|
    original = ENV["WEBHOOK_SECRET"]
    ENV["WEBHOOK_SECRET"] = secret
    example.run
    ENV["WEBHOOK_SECRET"] = original
  end

  it "rejects a wrong secret" do
    expect { post_payload(payload, token: "wrong") }.not_to change(HealthMetric, :count)

    expect(response).to have_http_status(:unauthorized)
  end

  it "stores a valid metric" do
    expect { post_payload(payload) }.to change(HealthMetric, :count).by(1)

    expect(response).to have_http_status(:ok)
    metric = HealthMetric.sole
    expect(metric).to have_attributes(metric_type: "sleep", source: "garmin_csv")
    expect(metric.recorded_date.to_s).to eq("2026-03-15")
    expect(metric.measurements["sleep_duration_seconds"]).to eq(27_000)
  end

  it "populates the generated column from the JSONB payload" do
    post_payload(payload)

    expect(HealthMetric.sole.sleep_score).to eq(82)
  end

  it "leaves generated columns for other types null" do
    post_payload(payload)

    expect(HealthMetric.sole).to have_attributes(hrv_ms: nil, weight_kg: nil, resting_hr_bpm: nil)
  end

  HealthMetric::METRIC_TYPES.each do |type|
    it "accepts the #{type} metric type" do
      post_payload(payload.merge("metric_type" => type))

      expect(response).to have_http_status(:ok)
      expect(HealthMetric.sole.metric_type).to eq(type)
    end
  end

  it "rejects an unknown metric type" do
    expect { post_payload(payload.merge("metric_type" => "vo2max")) }
      .not_to change(HealthMetric, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["errors"].first).to match(/unknown metric_type/)
  end

  it "rejects an unsupported schema_version" do
    post_payload(payload.merge("schema_version" => "2.0"))

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "rejects a missing recorded_date" do
    post_payload(payload.except("recorded_date"))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["errors"]).to include("recorded_date is required")
  end

  it "rejects an unparseable recorded_date" do
    post_payload(payload.merge("recorded_date" => "15/03/2026"))

    expect(response).to have_http_status(:unprocessable_content)
  end

  describe "idempotency" do
    it "updates rather than duplicating on the same date and type" do
      post_payload(payload)
      expect { post_payload(payload) }.not_to change(HealthMetric, :count)

      expect(response.parsed_body["status"]).to eq("updated")
    end

    it "replaces the stored values on re-export" do
      post_payload(payload)
      post_payload(payload.merge("values" => { "sleep_score" => 91 }))

      metric = HealthMetric.sole
      expect(metric.sleep_score).to eq(91)
      expect(metric.measurements).to eq("sleep_score" => 91)
    end

    it "treats a different metric type on the same date as a separate record" do
      post_payload(payload)

      expect { post_payload(payload.merge("metric_type" => "hrv")) }
        .to change(HealthMetric, :count).by(1)
    end
  end

  it "logs every delivery attempt" do
    post_payload(payload)
    post_payload(payload.merge("metric_type" => "bogus"))

    expect(WebhookLog.count).to eq(2)
    expect(WebhookLog.pluck(:status)).to contain_exactly("created", "rejected")
    expect(WebhookLog.where(endpoint: "/webhooks/health_metric").count).to eq(2)
  end
end
