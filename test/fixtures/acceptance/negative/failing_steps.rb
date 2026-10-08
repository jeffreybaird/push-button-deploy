# frozen_string_literal: true

Then("an intentional acceptance assertion fails") do
  expect(1).to eq(2)
end
