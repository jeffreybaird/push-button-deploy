# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notes::Create do
  context "with a valid title" do
    subject(:result) { described_class.call(attrs: { title: "Private release plan" }) }

    it("succeeds") { expect(result).to be_success }
    it("persists the title") { expect(result.value!.reload.title).to eq("Private release plan") }

    it "records the mutation identity" do
      note = result.value!
      expect(AuditLog.last.attributes).to include("event" => "notes.created", "record_id" => note.id)
    end

    it "records the mutation time" do
      result
      expect(AuditLog.last.created_at).not_to be_nil
    end

    it "does not record private note content" do
      note = result.value!
      expect(AuditLog.last.attributes.values).not_to include(note.title)
    end
  end

  context "with an empty title" do
    subject(:result) { described_class.call(attrs: { title: "" }) }

    it("fails") { expect(result).to be_failure }
    it("reports validation errors") { expect(result.failure).to eq([:validation, { title: ["can't be blank"] }]) }
    it("saves no note") { expect { result }.not_to change(Note, :count) }
    it("saves no audit") { expect { result }.not_to change(AuditLog, :count) }
  end

  context "when audit storage fails" do
    before { allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "audit unavailable") }

    it "rolls back the note", :aggregate_failures do
      expect { described_class.call(attrs: { title: "Atomic mutation" }) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(Note.count).to eq(0)
    end
  end

  context "with real commits", :commit do
    it "publishes only record identity after commit" do
      note = nil
      events = capture_events("notes.created") { note = described_class.call(attrs: { title: "Never log" }).value! }
      expect(events).to eq([{ note_id: note.id }])
    end

    it "does not publish or persist an enclosing rollback", :aggregate_failures do
      events = rolled_back_events("notes.created") { described_class.call(attrs: { title: "Rollback" }) }
      expect(events).to be_empty
      expect(Note.count).to eq(0)
      expect(AuditLog.count).to eq(0)
    end
  end
end
