# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Request parameter privacy", type: :request do
  subject(:filtered) { parameter_filter.filter(parameters) }

  let(:parameter_filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }
  let(:parameters) do
    {
      "note" => { "title" => "Confidential release plan" },
      "password" => "private-password",
      "api_token" => "private-token",
      "secret_key" => "private-key",
      "page" => "2"
    }
  end

  it "redacts nested note content from request logging" do
    expect(filtered.fetch("note")).to eq("title" => "[FILTERED]")
  end

  it "redacts standard credential fields" do
    expect(filtered.slice("password", "api_token", "secret_key").values).to eq(Array.new(3, "[FILTERED]"))
  end

  it "keeps harmless request metadata useful" do
    expect(filtered.fetch("page")).to eq("2")
  end

  it "preserves the original title for application persistence" do
    parameter_filter.filter(parameters)
    post "/notes", params: parameters.slice("note")
    expect(Note.last.title).to eq("Confidential release plan")
  end
end
