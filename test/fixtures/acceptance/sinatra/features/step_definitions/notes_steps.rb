# frozen_string_literal: true

When("I submit a note containing {string}") do |body|
  @submitted_body = body
  post "/notes", "body" => body
end

Then("the note is saved and displayed") do
  expect(last_response.status).to eq(302)
  follow_redirect!
  expect(last_response.status).to eq(200)
  expect(last_response.body).to include(@submitted_body)
  expect(Note.select_map(:body)).to eq([@submitted_body])
end

When("I submit an empty note") do
  post "/notes", "body" => "   "
end

Then("the request is rejected without saving a note") do
  expect(last_response.status).to eq(422)
  expect(Note.count).to eq(0)
end
