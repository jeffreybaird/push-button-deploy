# frozen_string_literal: true

Given("I am viewing my notes") do
  visit "/notes"
end

When("I save a note titled {string}") do |title|
  fill_in "Title", with: title
  find('[data-testid="save-note"]').click
end

Then("I see the note {string}") do |title|
  expect(page).to have_css('[data-testid="note-list"]', text: title)
end

When("I archive the note {string}") do |title|
  within('[data-testid="note"]', text: title) do
    find('[data-testid="archive-note"]').click
  end
end

Then("I no longer see the note {string}") do |title|
  expect(page).to have_no_css('[data-testid="note"]', text: title)
end

Then("the note {string} is retained in the archive") do |title|
  expect(Note.find_by!(title: title).archived_at).not_to be_nil
end

Then("I see a title validation error") do
  expect(page).to have_css('[data-testid="error-state"]', text: "Title can't be blank")
end

Then("no note has been saved") do
  expect(Note.count).to eq(0)
end
