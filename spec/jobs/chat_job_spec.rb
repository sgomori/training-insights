require "rails_helper"

RSpec.describe ChatJob do
  subject(:run) { described_class.perform_now("How is his buildup going?", "turn-1", version: version, today: today) }

  let(:today) { Runner.current_time_zone.today }
  let(:version) { Answers::Cache.version(today) }

  let(:turn) { ChatTurn.new(question: "How is his buildup going?", id: "turn-1") }

  around { |example| with_cache { example.run } }

  before { create(:runner, name: "Steve Gomori") }

  def delivered
    messages = []
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to) { |*args, **kwargs| messages << [ args, kwargs ] }
    run
    messages.sole
  end

  def answering_with(answer)
    allow(Ai::Chat).to receive(:call).and_return(answer)
  end

  def failing_with(error)
    allow(Ai::Chat).to receive(:call).and_raise(error)
  end

  describe "when the model answers" do
    before { answering_with("He is three weeks from his peak.") }

    it "pushes the answer to the turn that asked" do
      args, kwargs = delivered

      expect(args).to eq([ turn.stream_name ])
      expect(kwargs).to include(target: turn.dom_id, partial: "chats/answer")
      expect(kwargs[:locals][:answer]).to eq("He is three weeks from his peak.")
    end

    it "caches it, so the next visitor asking pays nothing" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
      run

      expect(Answers::Cache.answer_to("How is his buildup going?")).to eq("He is three weeks from his peak.")
    end

    # A run landing mid-turn moves the version on. The answer was computed
    # before it and must not be filed as though it accounted for it.
    it "files the answer under the version it was asked against" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
      asked_against = version
      create(:activity)

      described_class.perform_now("How is his buildup going?", "turn-1", version: asked_against, today: today)

      expect(Answers::Cache.answer_to("How is his buildup going?")).to be_nil
      expect(Answers::Cache.answer_to("How is his buildup going?", version: asked_against))
        .to eq("He is three weeks from his peak.")
    end

    it "tells the model who it is writing about" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
      run

      expect(Ai::Chat).to have_received(:call).with(hash_including(runner_name: "Steve Gomori"))
    end

    # The day the prompt states is the day the controller captured, which is
    # also half of the version the answer is filed under. Read afresh here, a
    # turn crossing midnight would state D+1 and be filed under D.
    it "tells the model the day the question was asked on, not the day it is answered" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
      asked_on = Date.new(2026, 9, 5)

      travel_to(Time.utc(2026, 9, 6, 12, 0, 0)) do
        described_class.perform_now("How is his buildup going?", "turn-1",
                                    version: Answers::Cache.version(asked_on), today: asked_on)
      end

      expect(Ai::Chat).to have_received(:call).with(hash_including(today: asked_on))
    end
  end

  # The job renders outside any request. A partial that quietly depended on
  # request context would pass every controller spec and fail only in front of a
  # visitor, so it is rendered here the way the broadcast does.
  describe "the partial it broadcasts" do
    def rendered(answer)
      ApplicationController.render(partial: "chats/answer", locals: { turn: turn, answer: answer })
    end

    it "renders with no request to lean on" do
      expect(rendered("He is three weeks out.")).to include(turn.dom_id)
    end

    it "gives the answer the id the pending bubble is waiting under" do
      expect(rendered("He is three weeks out.")).to include(%(id="#{turn.dom_id}"))
    end

    it "splits prose into paragraphs without a markup renderer" do
      expect(rendered("First.\n\nSecond.").scan("<p ").size).to eq(2)
    end

    it "does not trust what came back from the model" do
      expect(rendered("<script>alert(1)</script>")).not_to include("<script>")
    end
  end

  describe "when the model declines" do
    before { failing_with(Ai::Client::Refused.new("declined with cyber")) }

    it "says so in fixed words" do
      expect(delivered.last[:locals][:answer]).to eq(described_class::REFUSED)
    end

    it "caches nothing" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
      run

      expect(Answers::Cache.answer_to("How is his buildup going?")).to be_nil
    end
  end

  describe "when the model runs out of room" do
    before { failing_with(Ai::Client::Truncated.new("stopped at max_tokens")) }

    it "reports a failure rather than the front half of an answer" do
      expect(delivered.last[:locals][:answer]).to eq(described_class::FAILED)
    end

    it "caches nothing" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
      run

      expect(Answers::Cache.answer_to("How is his buildup going?")).to be_nil
    end
  end

  describe "when something else goes wrong" do
    before { failing_with(ActiveRecord::StatementInvalid.new("PG::UndefinedColumn: activities.foo")) }

    # An exception message in a chat bubble in front of an anonymous visitor is
    # an information leak, so the visitor gets a fixed string every time.
    it "never renders the exception" do
      answer = delivered.last[:locals][:answer]

      expect(answer).to eq(described_class::FAILED)
      expect(answer).not_to include("PG::")
    end

    it "logs the real error instead" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
      allow(Rails.logger).to receive(:error)

      run

      expect(Rails.logger).to have_received(:error).with(/PG::UndefinedColumn/)
    end

    # A retry would answer a visitor who has already been told it failed, and
    # would replace a bubble they may have scrolled past.
    it "does not raise, so the turn is not retried" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)

      expect { run }.not_to raise_error
    end
  end
end
