require "rails_helper"

# The chat and content services must not be able to reach the database.
#
# The risk is specific and it is on the generation side, not the chat side.
# RegenerateContentJob already holds an activity when it fires, and the model
# needs a public URL for the tools, so handing it rows directly would be the
# quicker thing to build. It would also create exactly the second path to the
# training data that routing everything through the public tool interface exists
# to prevent — one that no rate limit, key check or tool boundary sits in front
# of.
#
# A convention cannot enforce that, because the shortcut is always one line away.
# The structure is what enforces it: nothing under app/services/ai names a model,
# and nothing it calls issues a query.
RSpec.describe "the AI services' isolation from the database" do
  let(:sources) { Dir[Rails.root.join("app/services/ai/**/*.rb")] }
  let(:stub) { instance_double(Ai::Client, answer: "He has been running well.") }

  # Derived rather than listed, so a model added later joins the ban list on its
  # own instead of quietly falling outside a hand-maintained array.
  #
  # Answers::Cache is named explicitly because it is not a model and would
  # otherwise pass: it reads Activity and Race to derive a cache version, so
  # calling it from here would issue queries the regex could not see.
  def banned_names
    Rails.application.eager_load!
    ApplicationRecord.descendants.map(&:name) + %w[ActiveRecord ApplicationRecord Answers::Cache]
  end

  # Comments are where the next developer gets told why this rule exists, so they
  # are exempt from it.
  def code_lines(path)
    File.readlines(path).reject { |line| line.strip.start_with?("#") }
  end

  it "covers every file in the directory" do
    expect(sources).to be_present
  end

  it "names no model, and nothing that reads one" do
    patterns = banned_names.index_with { |name| /(?<![A-Za-z_])#{Regexp.escape(name)}(?![A-Za-z_])/ }

    found = sources.flat_map do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root)

      code_lines(path).flat_map.with_index(1) do |line, number|
        patterns.filter_map { |name, pattern| "#{relative}:#{number} references #{name}" if line.match?(pattern) }
      end
    end

    expect(found).to be_empty, "The AI services must reach training data only through the tools:\n  " +
                               found.join("\n  ")
  end

  # The static check catches a model named in source. This catches one reached
  # through a path the regex cannot see — and it runs against the entry points,
  # not just the prompt builders, because Ai::Content#call is where the shortcut
  # would actually go.
  def queries_during
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ])
    end

    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "issues no queries when a prompt is built" do
    create(:runner)

    expect(queries_during { Ai::ChatPrompt.for("Steve Gomori") }).to be_empty
    expect(queries_during { Ai::ContentPrompt.for("Steve Gomori") }).to be_empty
  end

  it "issues no queries when a question is answered" do
    create(:runner)
    create(:activity)

    queries = queries_during do
      Ai::Chat.call(question: "How is his buildup going?", runner_name: "Steve Gomori", client: stub)
    end

    expect(queries).to be_empty
  end

  it "issues no queries when the standing summary is written" do
    create(:runner)
    create(:activity)

    expect(queries_during { Ai::Content.call(runner_name: "Steve Gomori", client: stub) }).to be_empty
  end
end
