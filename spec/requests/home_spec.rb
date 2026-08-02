require "rails_helper"

RSpec.describe "Home" do
  describe "GET /" do
    it "renders" do
      create(:runner)

      get root_path

      expect(response).to have_http_status(:ok)
    end

    it "names the runner" do
      create(:runner, name: "Steve Gomori")

      get root_path

      expect(response.body).to include("Steve Gomori")
    end

    # A freshly provisioned instance serves this page before anything has been
    # seeded. It has to render, or the first thing a visitor sees is a 500.
    it "renders before a runner has been configured" do
      get root_path

      expect(response).to have_http_status(:ok)
    end

    it "advertises the MCP endpoint" do
      get root_path

      expect(response.body).to include("/mcp")
    end
  end

  describe "the next race" do
    before { create(:runner, timezone: "America/Toronto") }

    it "names an upcoming race" do
      create(:race, name: "Toronto Waterfront Marathon", race_date: 3.weeks.from_now.to_date)

      get root_path

      expect(response.body).to include("Toronto Waterfront Marathon")
    end

    it "omits races that have already been run" do
      create(:race, name: "Around the Bay", race_date: 2.weeks.ago.to_date, status: "completed")

      get root_path

      expect(response.body).not_to include("Around the Bay")
    end

    it "renders with no race on the calendar" do
      get root_path

      expect(response).to have_http_status(:ok)
    end
  end
end
