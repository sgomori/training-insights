require "rails_helper"

RSpec.describe "Home" do
  let(:zone) { ActiveSupport::TimeZone["America/Toronto"] }

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

  # The status line is the only place a visitor sees what the server holds, so
  # it is worth pinning that the figures are real rather than decorative.
  describe "the status line" do
    it "reports the tool count, the corpus and when the last run was" do
      create(:runner, timezone: "America/Toronto")
      create(:activity, activity_type: "running", started_at: zone.now - 2.days)
      create(:race, status: "completed", race_date: Date.current - 30)

      get root_path

      expect(response.body).to include("#{ToolRegistry::TOOLS.size}</span> tools")
      expect(response.body).to include("1</span> activity")
      expect(response.body).to include("1</span> race")
      expect(response.body).to include("2d ago")
    end

    it "renders on an instance holding nothing" do
      create(:runner)

      get root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("0</span> activities")
    end
  end

  describe "the sidebar" do
    before { create(:runner, timezone: "America/Toronto") }

    it "lists races still to come" do
      create(:race, name: "Royal Victoria Marathon", race_date: 3.weeks.from_now.to_date)

      get root_path

      expect(response.body).to include("Royal Victoria Marathon")
    end

    it "lists races already run, with their finish times" do
      create(:race, name: "Around the Bay", race_date: 2.weeks.ago.to_date,
                    status: "completed", result_time_seconds: 8_100)

      get root_path

      expect(response.body).to include("Around the Bay").and include("2:15:00")
    end

    it "keeps a race already run out of the upcoming block" do
      create(:race, name: "Around the Bay", race_date: 2.weeks.ago.to_date, status: "completed")

      get root_path

      expect(response.body).to include("Nothing on the calendar.")
    end

    it "lists recent runs by date, distance and pace" do
      create(:activity, started_at: zone.parse("2026-06-10 09:00"),
                        distance_meters: 12_100.0, average_pace_per_km: 342.0)

      get root_path

      expect(response.body).to include("12.1 km").and include("5:42/km")
    end

    # Heart rate stays in the tool responses and off the page.
    it "shows no heart rate" do
      create(:activity, average_heart_rate: 152, max_heart_rate: 178)

      get root_path

      expect(response.body).not_to include("152")
      expect(response.body).not_to include("178")
    end

    it "renders with nothing on the calendar and nothing recorded" do
      get root_path

      expect(response.body).to include("Nothing on the calendar.")
        .and include("No races run yet.")
        .and include("No runs recorded yet.")
    end
  end

  describe "the standing summary" do
    around { |example| with_cache { example.run } }

    before { create(:runner, name: "Steve Gomori") }

    it "opens the transcript when one has been written" do
      Answers::Cache.write_content("Volume has been climbing since May.")

      get root_path

      expect(response.body).to include("Volume has been climbing since May.")
    end

    # A fresh deployment has none until the first run lands, and the page still
    # has to say something useful.
    it "says so when there is none yet" do
      get root_path

      expect(response.body).to include("written when a new run arrives")
    end
  end

  describe "the suggested questions" do
    before { create(:runner, name: "Steve Gomori", timezone: "America/Toronto") }

    it "leads with the race being trained for" do
      create(:race, name: "Royal Victoria Marathon", race_date: 8.weeks.from_now.to_date)

      get root_path

      expect(response.body).to include("Is Steve ready for the Royal Victoria Marathon?")
    end

    it "falls back to general questions with nothing on the calendar" do
      get root_path

      expect(response.body).to include("How does this year compare with last year?")
    end
  end
end
