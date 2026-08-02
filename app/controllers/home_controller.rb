# The public face of the deployment. Read-only and unauthenticated throughout:
# there is one runner and there are no visitor accounts.
#
# The pre-generated content block and the chat surface both land here. Until
# they do, this renders the standing description of the project and the
# instructions for pointing an external MCP client at this instance.
class HomeController < ApplicationController
  def show
    @runner = Runner.current
    @next_race = Race.next_race
  end
end
