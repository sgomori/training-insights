require "rails_helper"

RSpec.describe "Chat" do
  let(:turbo) { { "Accept" => "text/vnd.turbo-stream.html, text/html" } }

  around { |example| with_cache { example.run } }

  before { create(:runner, name: "Steve Gomori") }

  def ask(question, headers: turbo)
    post chat_path, params: { question: question }, headers: headers
  end

  describe "a question that has not been answered yet" do
    it "enqueues the turn rather than answering it in the request" do
      expect { ask("How is his buildup going?") }
        .to have_enqueued_job(ChatJob).on_queue("chat")
    end

    it "appends the question and a pending bubble" do
      ask("How is his buildup going?")

      expect(response.body).to include("How is his buildup going?")
      expect(response.body).to include("turbo-cable-stream-source")
    end

    it "returns a stream rather than a page" do
      ask("How is his buildup going?")

      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    end
  end

  describe "a question already answered against the current data" do
    before { Answers::Cache.write_answer("How is his buildup going?", "It is going well.") }

    it "answers from the cache without a job" do
      expect { ask("How is his buildup going?") }.not_to have_enqueued_job(ChatJob)
    end

    it "renders the answer straight away" do
      ask("How is his buildup going?")

      expect(response.body).to include("It is going well.")
      expect(response.body).not_to include("turbo-cable-stream-source")
    end

    it "matches the question however it was typed" do
      ask("  how is HIS buildup   going? ")

      expect(response.body).to include("It is going well.")
    end

    # Ingestion moves the whole namespace, so an answer written before the run
    # is unreachable rather than merely old.
    it "goes back to the model once a new run has landed" do
      create(:activity)

      expect { ask("How is his buildup going?") }.to have_enqueued_job(ChatJob)
    end
  end

  describe "what it declines" do
    it "ignores an empty question" do
      expect { ask("   ") }.not_to have_enqueued_job(ChatJob)
      expect(response).to have_http_status(:no_content)
    end

    it "declines a question longer than it can take" do
      ask("why " * 300)

      expect(response.body).to include("longer than this can take")
    end

    it "does not enqueue one" do
      expect { ask("why " * 300) }.not_to have_enqueued_job(ChatJob)
    end
  end

  describe "without a stream-capable client" do
    it "sends the visitor back to the page" do
      ask("How is his buildup going?", headers: { "Accept" => "text/html" })

      expect(response).to redirect_to(root_path)
    end
  end
end
