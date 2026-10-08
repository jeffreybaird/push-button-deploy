# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notes::List do
  before do
    Note.create!(title: "First")
    Note.create!(title: "Second")
    Note.create!(title: "Archived", archived_at: Time.current)
  end

  it "returns default pagination metadata" do
    expect(described_class.call).to include(page: 1, per_page: 25, total: 2)
  end

  it "lists only kept titles" do
    expect(described_class.call.fetch(:items).map(&:title)).to contain_exactly("First", "Second")
  end

  it "pages without overlap", :aggregate_failures do
    first = described_class.call(page: 1, per_page: 1).fetch(:items).map(&:id)
    second = described_class.call(page: 2, per_page: 1).fetch(:items).map(&:id)
    expect(first.size).to eq(1)
    expect(second.size).to eq(1)
    expect(first & second).to be_empty
  end

  it "returns no items past the end" do
    expect(described_class.call(page: 3, per_page: 1).fetch(:items)).to be_empty
  end

  it "clamps pagination lower bounds" do
    expect(described_class.call(page: -4, per_page: 0)).to include(page: 1, per_page: 1)
  end

  it "caps page size at 100" do
    expect(described_class.call(page: 1, per_page: 999)).to include(per_page: 100)
  end
end
