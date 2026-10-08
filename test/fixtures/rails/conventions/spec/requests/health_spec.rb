# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Health", type: :request do
  it "confirms the database is reachable", :aggregate_failures do
    get "/health"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok")
  end

  it "keeps the alternate readiness route working", :aggregate_failures do
    get "/up"
    expect(response).to have_http_status(:ok)
  end
end
