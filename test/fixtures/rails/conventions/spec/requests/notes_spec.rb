# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Notes", type: :request do
  it "renders the home page and notes form", :aggregate_failures do
    get "/"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-testid="note-list"', 'data-testid="save-note"')
  end

  it "creates a note through the real request and shows it on the list", :aggregate_failures do
    post "/notes", params: { note: { title: "Ship the release" } }
    expect(response).to have_http_status(:redirect)
    follow_redirect!
    expect(response.body).to include("Ship the release")
    expect(Note.kept.pluck(:title)).to eq(["Ship the release"])
  end

  it "renders a validation error and preserves entered data without saving", :aggregate_failures do
    post "/notes", params: { note: { title: "" } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include('data-testid="error-state"')
    expect(Note.count).to eq(0)
  end

  it "archives through the real request and removes the note from the list", :aggregate_failures do
    note = Notes::Create.call(attrs: { title: "Done" }).value!
    patch "/notes/#{note.id}/archive"
    expect(response).to have_http_status(:redirect)
    expect(note.reload.archived_at).not_to be_nil
  end

  it "hides archived notes from the list" do
    note = Notes::Create.call(attrs: { title: "Done" }).value!
    Notes::Archive.call(id: note.id)
    get "/notes"
    expect(response.body).not_to include(">Done<")
  end

  it "does not pretend an unknown note was archived", :aggregate_failures do
    patch "/notes/999999/archive"
    expect(response).to have_http_status(:not_found)
  end
end
