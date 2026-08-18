require "rails_helper"

RSpec.describe Ai::Chat do
  let(:client) { instance_double(Ai::Client, answer: "He has been running well.") }

  def ask(question = "how is training going?", runner_name: "Steve Gomori")
    described_class.call(question: question, runner_name: runner_name, client: client)
  end

  it "returns the answer" do
    expect(ask).to eq("He has been running well.")
  end

  it "asks under the chat prompt" do
    ask

    expect(client).to have_received(:answer).with(hash_including(system: Ai::ChatPrompt.for("Steve Gomori")))
  end

  it "passes the question through unchanged" do
    ask("what did his last hard session look like?")

    expect(client).to have_received(:answer).with(hash_including(question: "what did his last hard session look like?"))
  end

  it "uses the configured chat model" do
    with_env("ANTHROPIC_CHAT_MODEL" => "claude-sonnet-5") { ask }

    expect(client).to have_received(:answer).with(hash_including(model: "claude-sonnet-5"))
  end
end
