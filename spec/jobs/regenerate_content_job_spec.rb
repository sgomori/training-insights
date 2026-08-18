require "rails_helper"

RSpec.describe RegenerateContentJob do
  let(:activity) { create(:activity) }

  around { |example| with_cache { example.run } }

  before { create(:runner, name: "Steve Gomori") }

  def run(activity_id = activity.id)
    described_class.perform_now(activity_id)
  end

  it "writes the standing summary" do
    allow(Ai::Content).to receive(:call).and_return("Volume has been climbing since May.")

    run

    expect(Answers::Cache.content).to eq("Volume has been climbing since May.")
  end

  it "tells the model who it is writing about" do
    allow(Ai::Content).to receive(:call).and_return("Volume has been climbing since May.")

    run

    expect(Ai::Content).to have_received(:call).with(hash_including(runner_name: "Steve Gomori"))
  end

  # The activity is a trigger, not an input: it is looked up to confirm the run
  # still exists and never reaches the model.
  it "does nothing when the activity it was told about has gone" do
    allow(Ai::Content).to receive(:call)

    run(0)

    expect(Ai::Content).not_to have_received(:call)
  end

  it "passes the model no training data" do
    allow(Ai::Content).to receive(:call).and_return("Volume has been climbing.")

    run

    expect(Ai::Content).to have_received(:call).with(hash_excluding(:activity, :activity_id))
  end

  describe "when generation fails" do
    # The previous summary stays readable and is out of date by one run.
    # Blanking it would be the worse failure.
    it "leaves the last one in place" do
      Answers::Cache.write_content("Volume has been climbing since May.")
      allow(Ai::Content).to receive(:call).and_raise(Ai::Client::Refused.new("declined"))

      run

      expect(Answers::Cache.content).to eq("Volume has been climbing since May.")
    end

    it "logs it" do
      allow(Ai::Content).to receive(:call).and_raise(Ai::Client::Empty.new("no text blocks"))
      allow(Rails.logger).to receive(:error)

      run

      expect(Rails.logger).to have_received(:error).with(/no text blocks/)
    end

    # Nobody is waiting on this one, which makes a retry the right answer to a
    # transient failure — unlike a chat turn, where the visitor has already been
    # told it went wrong.
    it "is configured to retry a transient failure rather than swallow it" do
      handled = described_class.rescue_handlers.map(&:first)

      expect(handled).to include("Anthropic::Errors::RateLimitError")
        .and include("Anthropic::Errors::APIConnectionError")
        .and include("Anthropic::Errors::InternalServerError")
    end
  end
end
