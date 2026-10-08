# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notes::Archive do
  let(:note) { Notes::Create.call(attrs: { title: "Finished" }).value! }

  context "when the note exists" do
    subject(:result) { described_class.call(id: note.id) }

    it("succeeds") { expect(result).to be_success }

    it "marks the note archived" do
      result
      expect(note.reload.archived_at).not_to be_nil
    end

    it "retains the record" do
      result
      expect(Note.exists?(note.id)).to be(true)
    end

    it "excludes the note from kept results" do
      result
      expect(Note.kept).not_to include(note)
    end

    it "audits creation and archive" do
      result
      expect(AuditLog.order(:id).pluck(:event)).to eq(%w[notes.created notes.archived])
    end
  end

  it "rejects an unknown note" do
    expect(described_class.call(id: -1).failure).to eq([:not_found])
  end

  it "rejects an already archived note without another audit", :aggregate_failures do
    described_class.call(id: note.id)
    expect(described_class.call(id: note.id).failure).to eq([:not_found])
    expect(AuditLog.count).to eq(2)
  end

  context "with real commits", :commit do
    before { note }

    it "publishes only the archived record identity" do
      events = capture_events("notes.archived") { described_class.call(id: note.id) }
      expect(events).to eq([{ note_id: note.id }])
    end

    it "rolls back an archive whose audit fails", :aggregate_failures do
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "audit unavailable")
      expect { described_class.call(id: note.id) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(note.reload.archived_at).to be_nil
      expect(AuditLog.count).to eq(1)
    end

    it "does not notify or archive an enclosing rollback", :aggregate_failures do
      events = rolled_back_events("notes.archived") { described_class.call(id: note.id) }
      expect(events).to be_empty
      expect(note.reload.archived_at).to be_nil
      expect(AuditLog.count).to eq(1)
    end
  end
end
