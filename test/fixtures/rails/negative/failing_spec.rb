# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Deliberate failure", type: :request do
  it "rejects a wrong health contract" do
    get "/health"
    expect(response).to have_http_status(:service_unavailable)
  end
end
