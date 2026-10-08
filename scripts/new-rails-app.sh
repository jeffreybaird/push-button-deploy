#!/usr/bin/env bash
# Generate a minimal Rails application without requiring a local Ruby toolchain.
set -euo pipefail
fail() { printf 'new-rails-app: %s\n' "$*" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${1:-}"
[ -n "$APP_DIR" ] || fail 'usage: new-rails-app.sh <app_dir>'
APP_NAME="$(basename "$APP_DIR")"
case "$APP_NAME" in
  *[!a-z0-9_]*|[!a-z]*|'') fail 'app directory name must be lower_snake_case, starting with a letter' ;;
esac
APP_MODULE="$(printf '%s' "$APP_NAME" | awk -F_ '{for(i=1;i<=NF;i++) printf "%s%s", toupper(substr($i,1,1)), substr($i,2)}')"
if [ ! -f "$APP_DIR/config/application.rb" ]; then
  [ ! -d "$APP_DIR" ] || [ -z "$(ls -A "$APP_DIR")" ] \
    || fail "$APP_DIR is not empty and has no config/application.rb — refusing to generate over it"
  mkdir -p "$APP_DIR"/{app/controllers,config/environments,db/migrate,bin,app/models,app/services/notes,app/views/notes,app/views/layouts,public/css,lib,tmp,log}
  printf '%s\n' "${RUBY_VERSION:-3.3.12}" > "$APP_DIR/.ruby-version"
  printf '%s\n' "$APP_NAME" > "$APP_DIR/.app-name"
  cat > "$APP_DIR/Gemfile" <<'RUBY'
# frozen_string_literal: true

source "https://rubygems.org"
ruby file: ".ruby-version"
gem "puma", "~> 7.2.1"
gem "rails", "~> 8.1.4"
gem "sqlite3", "~> 2.6"
# Security floors also override vulnerable Ruby default-gem versions.
gem "dry-monads", "~> 1.11"
gem "erb", ">= 6.0.4"
gem "rails-html-sanitizer", ">= 1.7.1"
gem "resolv", "~> 0.3.2"

group :development, :test do
  gem "bundler-audit", "~> 0.9", require: false
  gem "capybara", "~> 3.40", require: false
  gem "cucumber-rails", "~> 4.1", require: false
  gem "database_cleaner-active_record", "~> 2.2", require: false
  gem "rspec-rails", "~> 8.0", require: false
  gem "rubocop", "~> 1.91", require: false
  gem "rubocop-rails", "~> 2.38", require: false
  gem "rubocop-rspec", "~> 3.10", require: false
  gem "simplecov", "~> 1.3", require: false
end
RUBY
  cat > "$APP_DIR/config/boot.rb" <<'RUBY'
# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"
RUBY
  cat > "$APP_DIR/config/application.rb" <<RUBY
# frozen_string_literal: true

require_relative "boot"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
Bundler.require(*Rails.groups)

# Application namespace.
module $APP_MODULE
  # Configures the single-database Rails service.
  class Application < Rails::Application
    config.load_defaults 8.1
    config.filter_parameters += %i[title password secret token key authorization]
    # This service uses one SQLite database. No background workers or Solid
    # Queue/Cache/Cable databases are generated or booted implicitly.
    config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  end
end
RUBY
  cat > "$APP_DIR/config/environment.rb" <<'RUBY'
# frozen_string_literal: true

require_relative "application"
Rails.application.initialize!
RUBY
  cat > "$APP_DIR/config/environments/production.rb" <<'RUBY'
# frozen_string_literal: true

Rails.application.configure do
  config.eager_load = true
  config.enable_reloading = false
  config.consider_all_requests_local = false
  # Image source is immutable; migrations update the volume, not db/schema.rb.
  config.active_record.dump_schema_after_migration = false
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE") do
    ENV.fetch("SECRET_KEY_BASE_DUMMY", nil) && "build-only-dummy-secret"
  end
  # Caddy terminates HTTPS; internal Docker readiness probes use plain HTTP.
  config.assume_ssl = true
  config.force_ssl = true
  config.ssl_options = { redirect: { exclude: ->(request) { ["/health", "/up"].include?(request.path) } } }
  config.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))
end
RUBY
  cat > "$APP_DIR/config/environments/development.rb" <<'RUBY'
# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
end
RUBY
  cat > "$APP_DIR/config/environments/test.rb" <<'RUBY'
# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_controller.allow_forgery_protection = false
end
RUBY
  cat > "$APP_DIR/config/database.yml" <<'YAML'
default: &default
  adapter: sqlite3
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", 5) %>
  timeout: 5000
  pragmas:
    journal_mode: WAL
    foreign_keys: ON

development:
  <<: *default
  database: <%= ENV.fetch("DATABASE_PATH", "db/development.sqlite3").to_json %>
test:
  <<: *default
  database: <%= ENV.fetch("DATABASE_PATH", "db/test.sqlite3").to_json %>
production:
  <<: *default
  database: <%= ENV.fetch("DATABASE_PATH", "/data/app.db").to_json %>
YAML
  cat > "$APP_DIR/config/puma.rb" <<'RUBY'
# frozen_string_literal: true

max_threads = Integer(ENV.fetch("RAILS_MAX_THREADS", 5))
threads 1, max_threads
bind "tcp://0.0.0.0:#{ENV.fetch("PORT", 4000)}"
environment ENV.fetch("RAILS_ENV", "development")
RUBY
  cat > "$APP_DIR/config/routes.rb" <<'RUBY'
# frozen_string_literal: true

Rails.application.routes.draw do
  get "/health", to: "health#show"
  get "/up", to: "health#show"
  resources :notes, only: %i[index create] do
    patch :archive, on: :member
  end
  root "notes#index"
end
RUBY
  cat > "$APP_DIR/app/controllers/application_controller.rb" <<'RUBY'
# frozen_string_literal: true

# Shared HTTP behavior.
class ApplicationController < ActionController::Base
end
RUBY
  cat > "$APP_DIR/app/controllers/health_controller.rb" <<'RUBY'
# frozen_string_literal: true

# Readiness includes database connectivity.
class HealthController < ApplicationController
  def show
    ActiveRecord::Base.connection.execute("SELECT 1")
    render json: { status: "ok" }
  end
end
RUBY
  cat > "$APP_DIR/config.ru" <<'RUBY'
# frozen_string_literal: true

require_relative "config/environment"
run Rails.application
Rails.application.load_server
RUBY
  cat > "$APP_DIR/Rakefile" <<'RUBY'
# frozen_string_literal: true

require_relative "config/application"
Rails.application.load_tasks
RUBY
  cat > "$APP_DIR/bin/rails" <<'RUBY'
#!/usr/bin/env ruby
# frozen_string_literal: true

APP_PATH = File.expand_path("../config/application", __dir__)
require_relative "../config/boot"
require "rails/commands"
RUBY
  chmod +x "$APP_DIR/bin/rails"
  cat > "$APP_DIR/.gitignore" <<'IGNORE'
/.bundle
/vendor/bundle
/coverage
/.env
/.env.*
!/.env.example
/db/*.sqlite3*
/storage/*.sqlite3*
/log/*
/tmp/*
/config/master.key
/config/credentials/*.key
IGNORE
  cat > "$APP_DIR/README.md" <<'MD'
# Rails service

A Rails application using Active Record, SQLite and Puma. The Notes example
creates, lists and archives notes through domain services and server-rendered ERB.
It records durable audit events and publishes IDs-only notifications after commit.

```sh
bundle install
bin/rails db:prepare
bin/rails server -b 0.0.0.0 -p 4000
bin/check
```

`GET /health` returns HTTP 200 when the database is reachable. Production uses
`SECRET_KEY_BASE`, `DATABASE_PATH=/data/app.db` and `PORT=4000`. SQLite WAL is
replicated by Litestream. Deploy migrations run `bundle exec rails db:prepare`
before the healthy blue/green container receives traffic. Keep migrations
compatible with the previous release; image rollback does not undo migrations.

No Solid Queue, Solid Cache or Solid Cable services/databases are configured.
Add background jobs, extra databases or JavaScript build tooling deliberately,
with corresponding deployment and backup changes. See `AGENTS.md` and `.docs/`.

`bin/check` prepares the test database, runs RuboCop, RSpec and strict Cucumber,
then enforces 100% line and branch coverage across all application and library
Ruby files before checking current dependency advisories with bundler-audit.
Coverage results are cleared first; both suites must produce fresh results.
Keep Gemfile.lock committed. Before committing, run safe RuboCop autocorrection
on files you own, then rerun bin/check. Do not disable checks to pass.
MD
  mkdir -p "$APP_DIR/."
  cat > "$APP_DIR/.rubocop.yml" <<'SCAFFOLD'
plugins:
  - rubocop-rails
  - rubocop-rspec
AllCops:
  NewCops: enable
  TargetRubyVersion: 3.3
Style/StringLiterals:
  EnforcedStyle: double_quotes
Style/StringLiteralsInInterpolation:
  EnforcedStyle: double_quotes
SCAFFOLD
  mkdir -p "$APP_DIR/."
  cat > "$APP_DIR/.rspec" <<'SCAFFOLD'
--require spec_helper
--format progress
SCAFFOLD
  mkdir -p "$APP_DIR/bin"
  cat > "$APP_DIR/bin/check" <<'SCAFFOLD'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export RAILS_ENV=test
unset DATABASE_PATH DATABASE_URL PRIMARY_DATABASE_URL
rm -rf coverage
bundle exec rails db:prepare
bundle exec rubocop
bundle exec rspec
bundle exec cucumber --strict
bundle exec ruby script/coverage.rb
bundle exec bundler-audit check --update
SCAFFOLD
  mkdir -p "$APP_DIR/app/models"
  cat > "$APP_DIR/app/models/application_record.rb" <<'SCAFFOLD'
# frozen_string_literal: true

# Base class for application persistence.
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end
SCAFFOLD
  mkdir -p "$APP_DIR/app/models"
  cat > "$APP_DIR/app/models/note.rb" <<'SCAFFOLD'
# frozen_string_literal: true

# Recoverable content; archived rows remain available to deliberate recovery tools.
class Note < ApplicationRecord
  validates :title, presence: true
  scope :kept, -> { where(archived_at: nil) }
end
SCAFFOLD
  mkdir -p "$APP_DIR/app/models"
  cat > "$APP_DIR/app/models/audit_log.rb" <<'SCAFFOLD'
# frozen_string_literal: true

# Durable mutation identity, committed atomically with the application write.
class AuditLog < ApplicationRecord
end
SCAFFOLD
  mkdir -p "$APP_DIR/app/services/notes"
  cat > "$APP_DIR/app/services/notes/create.rb" <<'SCAFFOLD'
# frozen_string_literal: true

module Notes
  # Creates valid content and its durable audit in one transaction.
  module Create
    extend Dry::Monads[:result]

    def self.call(attrs:)
      note = Note.new(attrs)
      return Failure([:validation, note.errors.to_hash]) unless note.valid?

      Note.transaction { persist(note) }
      Success(note)
    end

    def self.persist(note)
      note.save!
      AuditLog.create!(event: "notes.created", record_id: note.id)
      ActiveRecord.after_all_transactions_commit do
        ActiveSupport::Notifications.instrument("notes.created", note_id: note.id)
      end
    end
    private_class_method :persist
  end
end
SCAFFOLD
  mkdir -p "$APP_DIR/app/services/notes"
  cat > "$APP_DIR/app/services/notes/archive.rb" <<'SCAFFOLD'
# frozen_string_literal: true

module Notes
  # Archives kept content without destroying it or duplicating audit events.
  module Archive
    extend Dry::Monads[:result]

    def self.call(id:)
      Note.transaction do
        note = Note.kept.find_by(id:)
        next Failure([:not_found]) unless note

        archive(note)
        Success(note)
      end
    end

    def self.archive(note)
      note.update!(archived_at: Time.current)
      AuditLog.create!(event: "notes.archived", record_id: note.id)
      ActiveRecord.after_all_transactions_commit do
        ActiveSupport::Notifications.instrument("notes.archived", note_id: note.id)
      end
    end
    private_class_method :archive
  end
end
SCAFFOLD
  mkdir -p "$APP_DIR/app/services/notes"
  cat > "$APP_DIR/app/services/notes/list.rb" <<'SCAFFOLD'
# frozen_string_literal: true

module Notes
  # Bounded, stable pagination over recoverable content that is still visible.
  module List
    def self.call(page: 1, per_page: 25)
      page = page.to_i.clamp(1, Float::INFINITY)
      per_page = per_page.to_i.clamp(1, 100)
      notes = Note.kept
      items = notes.order(created_at: :desc, id: :desc).limit(per_page).offset((page - 1) * per_page)
      { items: items.to_a, page:, per_page:, total: notes.count }
    end
  end
end
SCAFFOLD
  mkdir -p "$APP_DIR/app/controllers"
  cat > "$APP_DIR/app/controllers/notes_controller.rb" <<'SCAFFOLD'
# frozen_string_literal: true

# Translates HTTP input and service results; persistence belongs to Notes services.
class NotesController < ApplicationController
  def index
    render_index
  end

  def create
    attributes = params.expect(note: [:title]).to_h
    result = Notes::Create.call(attrs: attributes)
    return redirect_to notes_path, status: :see_other if result.success?

    render_index(note: Note.new(attributes), errors: result.failure.last, status: :unprocessable_content)
  end

  def archive
    result = Notes::Archive.call(id: params[:id])
    return head :not_found if result.failure?

    redirect_to notes_path, status: :see_other
  end

  private

  def render_index(note: Note.new, errors: {}, status: :ok)
    listing = Notes::List.call(page: params.fetch(:page, 1))
    render :index, locals: { note:, listing:, errors: }, status:
  end
end
SCAFFOLD
  mkdir -p "$APP_DIR/db/migrate"
  cat > "$APP_DIR/db/migrate/20261008000000_create_notes.rb" <<'SCAFFOLD'
# frozen_string_literal: true

# Establishes the content and minimal durable audit tables.
class CreateNotes < ActiveRecord::Migration[8.1]
  def change
    create_notes
    create_audit_logs
  end

  private

  def create_notes
    create_table :notes do |table|
      table.string :title, null: false
      table.datetime :archived_at
      table.timestamps
    end
    add_index :notes, %i[archived_at created_at id]
  end

  def create_audit_logs
    create_table :audit_logs do |table|
      table.string :event, null: false
      table.integer :record_id, null: false
      table.datetime :created_at, null: false
    end
    add_index :audit_logs, %i[record_id created_at]
  end
end
SCAFFOLD
  mkdir -p "$APP_DIR/app/views/layouts"
  cat > "$APP_DIR/app/views/layouts/application.html.erb" <<'SCAFFOLD'
<!DOCTYPE html>
<html lang="en">
  <head>
    <title>Notes</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <%= csrf_meta_tags %>
    <link rel="stylesheet" href="/css/app.css">
  </head>
  <body>
    <a class="skip-link" href="#main">Skip to content</a>
    <main id="main" tabindex="-1"><%= yield %></main>
  </body>
</html>
SCAFFOLD
  mkdir -p "$APP_DIR/app/views/notes"
  cat > "$APP_DIR/app/views/notes/index.html.erb" <<'SCAFFOLD'
<h1>Notes</h1>
<p>Keep a short list. Archive a note when you are done.</p>
<%= form_with model: note, url: notes_path, local: true do |form| %>
  <% if errors.any? %>
    <div id="title-errors" role="alert" data-testid="error-state">
      <% errors.each do |field, messages| %>
        <% messages.each do |message| %>
          <p><%= field.to_s.humanize %> <%= message %></p>
        <% end %>
      <% end %>
    </div>
  <% end %>
  <%= form.label :title, "Title" %>
  <%= form.text_field :title, aria: { invalid: errors.any?, describedby: ("title-errors" if errors.any?) } %>
  <%= form.submit "Save note", data: { testid: "save-note" } %>
<% end %>
<section aria-label="Saved notes" data-testid="note-list">
  <% if listing[:items].empty? %>
    <p data-testid="empty-state">No notes here. Save a note to get started.</p>
  <% else %>
    <ul>
      <% listing[:items].each do |item| %>
        <li data-testid="note">
          <span><%= item.title %></span>
          <%= button_to "Archive note", archive_note_path(item), method: :patch, data: { testid: "archive-note" } %>
        </li>
      <% end %>
    </ul>
  <% end %>
</section>
<nav aria-label="Notes pages">
  <% if listing[:page] > 1 %>
    <%= link_to "Previous page", notes_path(page: listing[:page] - 1) %>
  <% end %>
  <% if listing[:page] * listing[:per_page] < listing[:total] %>
    <%= link_to "Next page", notes_path(page: listing[:page] + 1) %>
  <% end %>
</nav>
SCAFFOLD
  mkdir -p "$APP_DIR/public/css"
  cat > "$APP_DIR/public/css/app.css" <<'SCAFFOLD'
/* Semantic tokens are the single source of design values. */
:root {
  --surface: #ffffff;
  --background: #f4f6fa;
  --text: #162237;
  --muted: #44546c;
  --accent: #1747a6;
  --accent-text: #ffffff;
  --error: #a32020;
  --border: #60718c;
  --focus: #7538ad;
  --space: 1rem;
  --radius: 0.4rem;
  --font-body: system-ui, sans-serif;
}
* { box-sizing: border-box; }
body { margin: 0; padding: var(--space); background: var(--background); color: var(--text); font: 1rem/1.6 var(--font-body); }
main { max-width: 46rem; margin: 2rem auto; padding: 2rem; background: var(--surface); border-radius: var(--radius); }
a { color: var(--accent); }
label { display: block; font-weight: 600; }
input[type="text"] { display: block; width: 100%; margin-block: 0.5rem var(--space); padding: 0.65rem; border: 1px solid var(--border); border-radius: var(--radius); font: inherit; }
button, input[type="submit"] { min-height: 44px; min-width: 44px; padding: 0.6rem var(--space); border: 0; border-radius: var(--radius); color: var(--accent-text); background: var(--accent); font: inherit; cursor: pointer; }
:focus-visible { outline: 3px solid var(--focus); outline-offset: 3px; }
[role="alert"] { color: var(--error); }
ul { list-style: none; padding: 0; }
li { display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: var(--space); padding-block: var(--space); border-bottom: 1px solid var(--border); }
li span { overflow-wrap: anywhere; }
nav { display: flex; gap: var(--space); }
nav a { display: inline-block; padding-block: 0.7rem; min-height: 44px; }
.skip-link { position: absolute; left: -10000px; }
.skip-link:focus { position: static; }
@media (max-width: 35rem) { main { margin-block: 0; padding: var(--space); } }
@media (prefers-reduced-motion: reduce) { *, *::before, *::after { scroll-behavior: auto; animation: none; transition: none; } }
SCAFFOLD
  mkdir -p "$APP_DIR/features"
  cat > "$APP_DIR/features/notes.feature" <<'SCAFFOLD'
Feature: Keeping notes
  Visitors keep a short list of notes and archive completed notes.

  Scenario: Create and archive a note
    Given I am viewing my notes
    When I save a note titled "Ship the release"
    Then I see the note "Ship the release"
    When I archive the note "Ship the release"
    Then I no longer see the note "Ship the release"
    And the note "Ship the release" is retained in the archive

  Scenario: Reject an empty title
    Given I am viewing my notes
    When I save a note titled ""
    Then I see a title validation error
    And no note has been saved
SCAFFOLD
  mkdir -p "$APP_DIR/features/step_definitions"
  cat > "$APP_DIR/features/step_definitions/notes_steps.rb" <<'SCAFFOLD'
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
SCAFFOLD
  mkdir -p "$APP_DIR/features/support"
  cat > "$APP_DIR/features/support/env.rb" <<'SCAFFOLD'
# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
ENV.delete("DATABASE_PATH")
ENV.delete("DATABASE_URL")
ENV.delete("PRIMARY_DATABASE_URL")
ENV["COVERAGE_SUITE"] = "cucumber"
require_relative "../../support/coverage"
require "cucumber/rails"
require "rspec/expectations"
require "database_cleaner/active_record"

World(RSpec::Matchers)
Capybara.default_driver = :rack_test
# Requests may lease different connections; each scenario owns real commits.
Cucumber::Rails::Database.autorun_database_cleaner = false
Around do |_scenario, run_scenario|
  cleaner = DatabaseCleaner[:active_record]
  cleaner.clean_with(:deletion)
  cleaner.strategy = :deletion
  cleaner.cleaning { run_scenario.call }
end
SCAFFOLD
  mkdir -p "$APP_DIR/script"
  cat > "$APP_DIR/script/coverage.rb" <<'SCAFFOLD'
# frozen_string_literal: true

require "simplecov"

results = %w[coverage/rspec/.resultset.json coverage/cucumber/.resultset.json]
abort "Both fresh RSpec and Cucumber coverage results are required" unless results.all? { |path| File.file?(path) }

SimpleCov.collate results do
  enable_coverage :branch
  track_files "{app,lib}/**/*.rb"
  add_filter do |source|
    !source.filename.start_with?("#{SimpleCov.root}/app/", "#{SimpleCov.root}/lib/")
  end
  minimum_coverage line: 100, branch: 100
end
SCAFFOLD
  mkdir -p "$APP_DIR/spec"
  cat > "$APP_DIR/spec/rails_helper.rb" <<'SCAFFOLD'
# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../config/environment"
require "rspec/rails"
require "database_cleaner/active_record"
require_relative "support/events"

ActiveRecord::Migration.maintain_test_schema!

RSpec.configure do |config|
  config.include EventCapture
  config.use_transactional_fixtures = false
  config.infer_spec_type_from_file_location!
  config.around do |example|
    DatabaseCleaner.strategy = example.metadata[:commit] ? :deletion : :transaction
    DatabaseCleaner.cleaning { example.run }
  end
end
SCAFFOLD
  mkdir -p "$APP_DIR/spec/requests"
  cat > "$APP_DIR/spec/requests/health_spec.rb" <<'SCAFFOLD'
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
SCAFFOLD
  mkdir -p "$APP_DIR/spec/requests"
  cat > "$APP_DIR/spec/requests/notes_spec.rb" <<'SCAFFOLD'
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
SCAFFOLD
  mkdir -p "$APP_DIR/spec/services/notes"
  cat > "$APP_DIR/spec/services/notes/archive_spec.rb" <<'SCAFFOLD'
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
SCAFFOLD
  mkdir -p "$APP_DIR/spec/services/notes"
  cat > "$APP_DIR/spec/services/notes/create_spec.rb" <<'SCAFFOLD'
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
SCAFFOLD
  mkdir -p "$APP_DIR/spec/services/notes"
  cat > "$APP_DIR/spec/services/notes/list_spec.rb" <<'SCAFFOLD'
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
SCAFFOLD
  mkdir -p "$APP_DIR/spec"
  cat > "$APP_DIR/spec/spec_helper.rb" <<'SCAFFOLD'
# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
ENV.delete("DATABASE_PATH")
ENV.delete("DATABASE_URL")
ENV.delete("PRIMARY_DATABASE_URL")
ENV["COVERAGE_SUITE"] = "rspec"
require_relative "../support/coverage"
require "rspec/core"

RSpec.configure do |config|
  config.order = :random
  config.fail_if_no_examples = true
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
end
SCAFFOLD
  mkdir -p "$APP_DIR/spec/support"
  cat > "$APP_DIR/spec/support/events.rb" <<'SCAFFOLD'
# frozen_string_literal: true

module EventCapture
  def capture_events(name)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(name) { |*args| events << args.last }
    yield events
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def rolled_back_events(name, &block)
    capture_events(name) { rollback_change(&block) }
  end

  def rollback_change
    Note.transaction do
      yield
      raise ActiveRecord::Rollback
    end
  end
end
SCAFFOLD
  mkdir -p "$APP_DIR/support"
  cat > "$APP_DIR/support/coverage.rb" <<'SCAFFOLD'
# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch
  track_files "{app,lib}/**/*.rb"
  command_name ENV.fetch("COVERAGE_SUITE")
  coverage_dir "coverage/#{ENV.fetch("COVERAGE_SUITE")}"
  add_filter do |source|
    !source.filename.start_with?("#{SimpleCov.root}/app/", "#{SimpleCov.root}/lib/")
  end
  finalize_merge false
end
SCAFFOLD
  cat > "$APP_DIR/spec/requests/privacy_spec.rb" <<'SCAFFOLD'
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
SCAFFOLD
  chmod +x "$APP_DIR/bin/check"
fi
# Existing Rails application source stays intact; docs are lifecycle-managed.
. "$SCRIPT_DIR/claude-docs.sh"
cd_inject "$SCRIPT_DIR/../app-template-rails" "$APP_DIR" "$APP_MODULE" "$APP_NAME"
