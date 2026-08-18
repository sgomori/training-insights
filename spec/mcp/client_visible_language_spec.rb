require "rails_helper"

# Everything a client reads is prose this application chose to send. None of it
# should describe how the application is built.
#
# The concern is not that a client could interrogate the server — it cannot, the
# tools take typed parameters and run fixed queries. It is that prose written to
# explain a gap in the data can name the machinery that left the gap, and a
# client will faithfully relay that to whoever asked. A runner asking whether
# they are ready to race should never learn what the data was parsed by.
#
# Two surfaces, one rule: the tool descriptions and runtime notes an external
# client reads, and the system prompts behind this site's own chat.
RSpec.describe "language visible outside this application" do
  FORBIDDEN = {
    "n8n" => /\bn8n\b/i,
    "Garmin" => /\bgarmin\b/i,
    "FIT files" => /\bfit files?\b/i,
    "the pipeline" => /\bpipelines?\b/i,
    "ingestion" => /\bingest(ion|ed|s)?\b/i,
    "webhooks" => /\bwebhooks?\b/i,
    "PostgreSQL" => /\bpostgres(ql)?\b/i,
    "Rails" => /\brails\b/i,
    "Active Record" => /\bactive ?record\b/i,
    "Solid Queue" => /\bsolid (queue|cache|cable)\b/i,
    "Ruby" => /\bruby\b/i,
    "SQL" => /\bsql\b/i
  }.freeze

  def offences(text, label)
    FORBIDDEN.filter_map { |term, pattern| "#{label} mentions #{term}" if text.match?(pattern) }
  end

  describe "the static surface every client reads on connect" do
    it "describes analysis rather than implementation" do
      found = offences(ToolRegistry::INSTRUCTIONS, "server instructions")

      ToolRegistry::TOOLS.each do |tool|
        found.concat(offences(tool.description_value.to_s, "#{tool.tool_name} description"))

        schema = tool.input_schema.to_h
        schema.dig(:properties)&.each do |name, property|
          found.concat(offences(property[:description].to_s, "#{tool.tool_name}.#{name} description"))
        end
      end

      expect(found).to be_empty, "Client-visible text leaks implementation detail:\n  #{found.join("\n  ")}"
    end
  end

  # Notes, bases and caveats are built at call time, so they cannot be
  # enumerated without invoking every tool against every shape of missing data.
  # Reading the source is the cheaper guard, and the leaks it is written to
  # catch have all been in exactly these prose strings.
  describe "the prose the tools assemble at runtime" do
    PROSE_FILES = (
      Dir[Rails.root.join("app/mcp/analytical_tools/*.rb")] +
        [ Rails.root.join("app/mcp/tool_registry.rb").to_s,
          Rails.root.join("app/mcp/metric_interpretation.rb").to_s,
          Rails.root.join("app/mcp/training_window.rb").to_s,
          Rails.root.join("app/mcp/training_context.rb").to_s,
          Rails.root.join("app/mcp/lap_segmentation.rb").to_s ]
    ).freeze

    # Comments explain the implementation to the next developer and are exactly
    # where words like "Postgres" belong.
    def prose_lines(path)
      File.readlines(path).reject { |line| line.strip.start_with?("#") }.select { |line| line.include?('"') }
    end

    it "describes analysis rather than implementation" do
      found = PROSE_FILES.flat_map do |path|
        relative = Pathname.new(path).relative_path_from(Rails.root)

        prose_lines(path).flat_map.with_index(1) do |line, _|
          number = File.readlines(path).index(line).to_i + 1
          offences(line, "#{relative}:#{number}")
        end
      end

      expect(found).to be_empty, "Client-visible text leaks implementation detail:\n  #{found.uniq.join("\n  ")}"
    end
  end

  # The web chat is the same concern with a shorter fuse. The model there has no
  # filesystem and no repository, so it can only relay what the prompt or a tool
  # result put in front of it — which makes the system prompt the whole
  # disclosure surface. The prompt is also the thing that gets tuned against real
  # output, and that is exactly when someone reaches for a sentence explaining
  # why a metric is missing in terms of the machinery that left the gap.
  #
  # The rendered prompt is checked rather than its source, because it is what the
  # model is actually given.
  describe "the prompts behind the site's own chat" do
    it "describes analysis rather than implementation" do
      found = offences(Ai::ChatPrompt.for("Steve Gomori"), "the chat prompt") +
              offences(Ai::ContentPrompt.for("Steve Gomori"), "the content prompt") +
              offences(Ai::ContentPrompt.request, "the content request") +
              offences(Ai::Voice.rules("Steve Gomori"), "the voice rules")

      expect(found).to be_empty, "Client-visible text leaks implementation detail:\n  #{found.join("\n  ")}"
    end

    # The rules are shared rather than written twice, so the two prompts cannot
    # drift into promising a visitor different things on the same page.
    it "gives both prompts the same voice" do
      rules = Ai::Voice.rules("Steve Gomori")

      expect(Ai::ChatPrompt.for("Steve Gomori")).to include(rules)
      expect(Ai::ContentPrompt.for("Steve Gomori")).to include(rules)
    end

    # The one constraint that is real on this surface and meaningless in someone
    # else's client, so it can only live here.
    it "bans heart rate figures from the site" do
      expect(Ai::Voice.rules("Steve Gomori")).to match(/Never state a heart rate/)
    end
  end
end
