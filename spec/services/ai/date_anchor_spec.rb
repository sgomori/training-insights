require "rails_helper"

RSpec.describe Ai::DateAnchor do
  subject(:anchor) { described_class.for(Date.new(2026, 9, 5)) }

  it "states the day in full" do
    expect(anchor).to include("Today is Saturday 5 September 2026.")
  end

  # The model's habit is to date a question from its training rather than the
  # calendar. Two worked examples, one either side of today, pin the rule down
  # harder than the sentence stating it.
  it "resolves a year-less date to its most recent occurrence" do
    expect(anchor).to include("29 August means 2026")
    expect(anchor).to include("12 September means 2025")
  end

  it "keeps the examples right across a year boundary" do
    at_new_year = described_class.for(Date.new(2027, 1, 3))

    expect(at_new_year).to include("27 December means 2026")
    expect(at_new_year).to include("10 January means 2026")
  end

  # 29 February of a non-leap year is not a day, and an example that names one
  # teaches the rule wrong.
  it "never names a leap day the previous year did not have" do
    before_leap_day = described_class.for(Date.new(2028, 2, 22))

    expect(before_leap_day).to include("1 March means 2027")
    expect(before_leap_day).not_to include("29 February")
  end

  # A race is asked about before it happens, so the backward rule must not
  # drag an upcoming date into the previous year.
  it "reads a date that is still to come forwards" do
    expect(anchor).to match(/still to come.*next occurrence on or after today/m)
  end

  it "asks the model to say how it read an ambiguous date" do
    expect(anchor).to match(/say which day you took it to be/)
  end
end
