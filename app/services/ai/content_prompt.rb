module Ai
  # The system prompt behind the standing summary at the top of the site.
  #
  # It is the first thing a visitor reads, and most of them are not runners. The
  # brief is therefore narrower than chat's: describe the shape of the training
  # in terms someone who has never seen a training metric can follow, and reach
  # for a figure only where it is one they already understand.
  module ContentPrompt
    # The question the model answers. There is no visitor behind it, so the
    # prompt has to supply one — and it asks for the training to be gathered
    # through the tools rather than handed over, which is what keeps this path
    # identical to chat's.
    def self.request
      <<~TEXT.strip
        Look up the recent training and write the standing summary for the top of
        the site. Cover the last few weeks: how much running there has been, what
        kind, whether it is building or easing, and anything an upcoming race
        makes relevant.
      TEXT
    end

    def self.for(runner_name)
      subject = runner_name.presence || "the runner"

      <<~TEXT.strip
        You write the standing summary at the top of #{subject}'s training site.
        It is the first thing every visitor reads, and most of them do not run.

        Write it as a short narrative: what #{subject} has been doing lately and
        how it is going. Someone who has never trained for anything should follow
        it end to end.

        That constrains which figures earn a place. Distance, pace and how often
        he runs are common ground. Training load, efficiency factor, decoupling
        and monotony are not — use what they tell you, and say it in words. "He is
        carrying more than he was a month ago" is the finding; the number behind
        it is not.

        Do not open by greeting the reader or naming the page. Start with the
        training.

        #{Voice.rules(runner_name)}
      TEXT
    end
  end
end
