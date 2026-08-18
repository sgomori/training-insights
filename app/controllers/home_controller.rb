# The public face of the deployment. Read-only and unauthenticated throughout:
# there is one runner and there are no visitor accounts.
#
# It reads records directly, which the chat and content services must not. The
# rule they are held to is about what reaches the model — the sidebar is this
# application rendering its own database onto its own page, and the model never
# sees any of it.
class HomeController < ApplicationController
  SHOWN = 3

  def show
    @runner = Runner.current
    @time_zone = Runner.current_time_zone

    # Loaded rather than left as relations: suggested_prompts reads the first
    # upcoming race, and on an unloaded relation that is its own query before the
    # sidebar runs the same one again.
    @upcoming_races = Race.upcoming.where(race_date: @time_zone.today..).limit(SHOWN).to_a
    @recent_races = Race.completed.limit(SHOWN).to_a
    @recent_runs = Activity.of_type("running").most_recent_first.limit(SHOWN).to_a

    @summary = Answers::Cache.content
    @suggested_prompts = suggested_prompts
    @status = status
  end

  private

  # The header status line. Real figures rather than decoration: it is the one
  # place a visitor can see what the server actually holds, and it doubles as a
  # smoke test — a zero here means ingestion is broken, not that the page is.
  def status
    {
      tools: ToolRegistry::TOOLS.size,
      activities: Activity.count,
      races: Race.completed.count,
      last_run: @recent_runs.first&.started_at&.in_time_zone(@time_zone)&.to_date
    }
  end

  # Derived from the calendar rather than fixed, so the first question on offer
  # is about the race actually being trained for. Each is phrased the way a
  # visitor would ask it, because that phrasing is the key its answer caches
  # under — and a question two visitors ask the same way is answered once.
  def suggested_prompts
    name = @runner&.name&.split&.first || "the runner"
    next_race = @upcoming_races.first

    prompts = []
    prompts << "Is #{name} ready for the #{next_race.name}?" if next_race
    prompts << "How has #{name}'s training been going lately?"
    prompts << "What did #{name}'s last hard session look like?"
    prompts << "How does this year compare with last year?" if next_race.nil?
    prompts
  end
end
