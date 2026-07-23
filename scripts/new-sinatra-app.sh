#!/usr/bin/env bash
#
# new-sinatra-app.sh — scaffold a runnable Sinatra + Sequel + SQLite app and drop
# in the Claude skill docs. The Sinatra counterpart to scripts/inject-skill-docs.sh
# (which handles Phoenix apps). Invoked by bootstrap.sh's ensure_app when
# FRAMEWORK=sinatra; also runnable by hand.
#
#   ./scripts/new-sinatra-app.sh <app_dir>
#
# What it does:
#   1. Derives APP_NAME (dir basename, lower_snake_case) + APP_MODULE (camelized).
#   2. Scaffolds a modular Sinatra app (class App < Sinatra::Base) served by Puma:
#      Gemfile, config.ru, config/{environment,database,puma}.rb, app.rb, an
#      example Note resource (model + Sequel migration + service object returning
#      a dry-monads Result), ERB views, and an RSpec suite (Rack::Test + Capybara).
#      SQLite via Sequel; WAL mode + busy_timeout set for Litestream replication.
#   3. Copies the skill docs from app-template-ruby/ (CLAUDE.md + .claude/*.md +
#      the cloud-environment SessionStart hook), rewriting the MyApp / my_app
#      placeholders to the app's real names.
#   4. Writes .app-name (the deploy/rollback workflows read it — a Rack app has no
#      mix.exs to parse).
#
# If <app_dir> already contains a Gemfile it is treated as an existing app: only
# step 3 (skill docs) runs, so it doubles as a retrofit for a hand-written app.
#
# Portable: BSD/macOS bash, awk, perl.
set -euo pipefail

fail() { printf 'new-sinatra-app: %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../app-template-ruby"
RUBY_PIN="${RUBY_VERSION:-3.3.6}"

APP_DIR="${1:-}"
[ -n "$APP_DIR" ] || fail "usage: new-sinatra-app.sh <app_dir>"
[ -f "$TEMPLATE_DIR/CLAUDE.md" ] || fail "no CLAUDE.md in $TEMPLATE_DIR"
[ -d "$TEMPLATE_DIR/.claude" ]   || fail "no .claude/ in $TEMPLATE_DIR"

APP_NAME="$(basename "$APP_DIR")"
case "$APP_NAME" in
  [a-z]*[!a-z0-9_]*|*[!a-z0-9_]*|[!a-z]*)
    fail "app name '$APP_NAME' must be lower_snake_case (start with a letter): the dir basename names the app" ;;
esac
APP_MODULE="$(printf '%s' "$APP_NAME" | awk -F_ '{o=""; for(i=1;i<=NF;i++){o=o toupper(substr($i,1,1)) substr($i,2)} print o}')"

# ---- 1/2. scaffold the app (skipped when a Gemfile already exists) --------------
scaffold() {
  [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ] \
    && fail "$APP_DIR is not empty and has no Gemfile — refusing to scaffold over it"
  log "scaffolding Sinatra app '$APP_NAME' ($APP_MODULE) in $APP_DIR"
  mkdir -p "$APP_DIR"/{config,app/models,app/services/notes,app/clients,app/policies,db/migrate,views/notes,public/css,spec/services/notes,spec/requests}

  printf '%s\n' "$RUBY_PIN"  > "$APP_DIR/.ruby-version"
  printf '%s\n' "$APP_NAME"  > "$APP_DIR/.app-name"

  cat > "$APP_DIR/Gemfile" <<'RUBY'
# frozen_string_literal: true

source "https://rubygems.org"

# One source of truth for the Ruby version: .ruby-version (the Dockerfile's
# RUBY_VERSION ARG and CI's ruby-version-file read the same file).
ruby file: ".ruby-version"

gem "sinatra", "~> 4.1", require: "sinatra/base" # modular app, no classic DSL
gem "puma", "~> 6.6"                             # app server (config/puma.rb)
gem "rackup", "~> 2.2"                           # `run App` entrypoint (config.ru)
gem "sequel", "~> 5.90"                          # ORM + migrations
gem "sqlite3", "~> 2.6"                          # the only DB backend
gem "rake", "~> 13.2"                            # `rake db:migrate` (the deploy gate)
gem "dry-monads", "~> 1.8", require: "dry/monads" # Success/Failure Results
gem "faraday", "~> 2.13"                         # HTTP client for service wrappers

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rack-test", "~> 2.2", require: "rack/test"
  gem "factory_bot", "~> 6.5"
  gem "dotenv", "~> 3.1"
end

group :test do
  gem "capybara", "~> 3.40"
end
RUBY

  cat > "$APP_DIR/config.ru" <<'RUBY'
# frozen_string_literal: true

require_relative "config/environment"

run App
RUBY

  cat > "$APP_DIR/config/environment.rb" <<'RUBY'
# frozen_string_literal: true

# Boot order: Bundler -> DB (+ Sequel plugins) -> app code -> the Sinatra app.
require "bundler/setup"
Bundler.require(:default, ENV.fetch("RACK_ENV", "development").to_sym)

require_relative "database"

require_relative "../app/current"
Dir[File.expand_path("../app/models/**/*.rb", __dir__)].sort.each   { |f| require f }
Dir[File.expand_path("../app/services/**/*.rb", __dir__)].sort.each { |f| require f }
Dir[File.expand_path("../app/policies/**/*.rb", __dir__)].sort.each { |f| require f }

require_relative "../app"
RUBY

  cat > "$APP_DIR/config/database.rb" <<'RUBY'
# frozen_string_literal: true

require "sequel"

# DATABASE_PATH is set by the deploy stack (an on-volume file, e.g.
# /data/app.sqlite3). In dev/test it defaults to a per-environment file.
db_path = ENV.fetch("DATABASE_PATH") do
  env = ENV.fetch("RACK_ENV", "development")
  File.expand_path("../db/#{env}.sqlite3", __dir__)
end

# The single global connection. SQLite is one file, one writer at a time — see
# .claude/database.md before doing anything write-heavy.
DB = Sequel.connect(adapter: "sqlite", database: db_path)

# WAL: readers don't block the single writer, and it's what Litestream replicates.
# busy_timeout: wait (don't instantly error) when another write holds the lock.
DB.run "PRAGMA journal_mode=WAL"
DB.run "PRAGMA busy_timeout=5000"
DB.run "PRAGMA foreign_keys=ON"

# App-wide model plugins (models are defined after this file loads).
Sequel::Model.plugin :timestamps, update_on_create: true
Sequel::Model.plugin :validation_helpers
RUBY

  cat > "$APP_DIR/config/puma.rb" <<'RUBY'
# frozen_string_literal: true

# Binds 0.0.0.0:$PORT so Caddy (by container name) and the compose healthcheck
# (127.0.0.1) both reach it. Keep the thread count modest: SQLite serializes
# writes, so more threads mainly means more lock contention.
port        Integer(ENV.fetch("PORT", 4000))
environment ENV.fetch("RACK_ENV", "development")
threads     1, Integer(ENV.fetch("PUMA_MAX_THREADS", 5))
# No pidfile: the container is ephemeral and runs unprivileged.
RUBY

  cat > "$APP_DIR/app.rb" <<'RUBY'
# frozen_string_literal: true

require "sinatra/base"
require "securerandom"

# The application. Routes stay thin: parse params, call a service object, render.
# Business rules and SQL live in app/services and app/models — never here.
class App < Sinatra::Base
  configure do
    set :root, __dir__
    set :erb, escape_html: true
    set :sessions, secret: ENV.fetch("SECRET_KEY_BASE") { SecureRandom.hex(64) }
    enable :logging
    set :show_exceptions, false if ENV["RACK_ENV"] == "production"
  end

  # Current is the request-scoped data boundary (NOT authorization). Reset it
  # around every request so nothing leaks between them.
  before do
    Current.reset!
    Current.request_id = env["HTTP_X_REQUEST_ID"] || SecureRandom.uuid
  end
  after { Current.reset! }

  # Liveness/readiness: 200 once the process can reach the DB.
  get "/up" do
    DB.test_connection
    content_type :json
    '{"status":"ok"}'
  end

  get "/" do
    @notes = Note.recent.limit(50).all
    erb :"notes/index"
  end

  post "/notes" do
    result = Notes::Create.call(params)
    if result.success?
      redirect "/"
    else
      @errors = result.failure
      @notes  = Note.recent.limit(50).all
      status 422
      erb :"notes/index"
    end
  end
end
RUBY

  cat > "$APP_DIR/app/current.rb" <<'RUBY'
# frozen_string_literal: true

# Request-scoped context, thread-local so concurrent Puma threads don't share it.
# This is the DATA boundary (who/which tenant) — authorization lives in policies.
module Current
  class << self
    def user       = store[:user]
    def account    = store[:account]
    def request_id = store[:request_id]

    # Ruby forbids endless setter methods, so these stay classic.
    def user=(value)    ; store[:user] = value        ; end
    def account=(value) ; store[:account] = value      ; end
    def request_id=(id) ; store[:request_id] = id      ; end

    def reset!
      Thread.current[:current_attributes] = {}
    end

    private

    def store
      Thread.current[:current_attributes] ||= {}
    end
  end
end
RUBY

  cat > "$APP_DIR/app/models/note.rb" <<'RUBY'
# frozen_string_literal: true

# Persistence + invariants for a note. Business orchestration belongs in a
# service object (app/services/notes/), not here.
class Note < Sequel::Model
  dataset_module do
    def recent = order(Sequel.desc(:created_at))
  end

  def validate
    super
    validates_presence :body
    validates_max_length 10_000, :body, allow_nil: false
  end
end
RUBY

  cat > "$APP_DIR/app/services/notes/create.rb" <<'RUBY'
# frozen_string_literal: true

require "dry/monads"

module Notes
  # One object, one job, one #call. Returns a tagged Result the route branches on
  # — never a bare boolean/nil. See .claude/architecture-decisions.md.
  class Create
    include Dry::Monads[:result]

    def self.call(...) = new.call(...)

    def call(attrs)
      note = Note.new(body: attrs["body"].to_s.strip)
      return Failure([:validation, note.errors]) unless note.valid?

      note.save
      Success(note)
    rescue Sequel::DatabaseError => e
      Failure([:error, e.message])
    end
  end
end
RUBY

  cat > "$APP_DIR/db/migrate/001_create_notes.rb" <<'RUBY'
# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:notes) do
      primary_key :id
      String   :body, text: true, null: false
      DateTime :created_at
      DateTime :updated_at
    end
  end
end
RUBY

  cat > "$APP_DIR/Rakefile" <<'RUBY'
# frozen_string_literal: true

require "sequel"
Sequel.extension :migration

namespace :db do
  desc "Run pending migrations"
  task :migrate do
    require_relative "config/database"
    Sequel::Migrator.run(DB, "db/migrate")
    puts "migrated: #{DB.opts[:database]}"
  end

  desc "Roll back the last migration"
  task :rollback do
    require_relative "config/database"
    current = Sequel::Migrator.new(DB, "db/migrate").current
    Sequel::Migrator.run(DB, "db/migrate", target: [current - 1, 0].max)
  end
end

begin
  require "rspec/core/rake_task"
  RSpec::Core::RakeTask.new(:spec)
  task default: :spec
rescue LoadError
  # rspec is a dev/test gem; absent in production images. That's fine.
end
RUBY

  cat > "$APP_DIR/views/layout.erb" <<'ERB'
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Notes</title>
    <link rel="stylesheet" href="/css/app.css">
  </head>
  <body>
    <main>
      <%= yield %>
    </main>
  </body>
</html>
ERB

  cat > "$APP_DIR/views/notes/index.erb" <<'ERB'
<h1>Notes</h1>

<% if defined?(@errors) && @errors %>
  <div role="alert" data-testid="form-errors">
    Could not save the note. Check the field below.
  </div>
<% end %>

<form method="post" action="/notes" data-testid="new-note-form">
  <label for="note_body">Note</label>
  <textarea id="note_body" name="body" required></textarea>
  <button type="submit">Add note</button>
</form>

<ul data-testid="notes-list">
  <% @notes.each do |note| %>
    <li data-testid="note"><%= note.body %></li>
  <% end %>
</ul>
ERB

  cat > "$APP_DIR/public/css/app.css" <<'CSS'
:root { --fg: #1a1a1a; --bg: #ffffff; --accent: #2563eb; }
* { box-sizing: border-box; }
body { font-family: system-ui, sans-serif; color: var(--fg); background: var(--bg); max-width: 42rem; margin: 2rem auto; padding: 0 1rem; }
label { display: block; font-weight: 600; margin-bottom: .25rem; }
textarea { width: 100%; min-height: 4rem; }
button { background: var(--accent); color: #fff; border: 0; padding: .5rem 1rem; border-radius: .375rem; cursor: pointer; }
button:focus-visible { outline: 3px solid #93c5fd; outline-offset: 2px; }
[role="alert"] { color: #b91c1c; margin: 1rem 0; }
CSS

  cat > "$APP_DIR/spec/spec_helper.rb" <<'RUBY'
# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
# Isolated, disposable test DB — recreated from migrations before every run.
ENV["DATABASE_PATH"] ||= File.expand_path("../db/test.sqlite3", __dir__)
File.delete(ENV["DATABASE_PATH"]) if File.exist?(ENV["DATABASE_PATH"])

# Migrate BEFORE the app loads: a Sequel::Model introspects its table at
# require-time, so the schema must already exist. Connect (config/database),
# migrate, THEN load the models + app (config/environment).
require_relative "../config/database"
Sequel.extension :migration
Sequel::Migrator.run(DB, File.expand_path("../db/migrate", __dir__))

require_relative "../config/environment"

require "rack/test"
require "capybara/rspec"
Capybara.app = App

module RequestHelpers
  include Rack::Test::Methods
  def app = App
end

RSpec.configure do |config|
  config.include RequestHelpers, type: :request
  config.include RequestHelpers, type: :feature

  # Each example runs in a transaction rolled back at the end — fast, isolated,
  # and safe against SQLite's single writer (one connection throughout).
  config.around(:each) do |example|
    DB.transaction(rollback: :always, savepoint: true) { example.run }
  end

  config.order = :random
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
RUBY

  cat > "$APP_DIR/spec/services/notes/create_spec.rb" <<'RUBY'
# frozen_string_literal: true

require "spec_helper"

RSpec.describe Notes::Create do
  it "creates a note from valid params" do
    result = described_class.call("body" => "hello world")

    expect(result.success?).to be(true)
    expect(result.value!.body).to eq("hello world")
    expect(Note.count).to eq(1)
  end

  it "fails with a tagged Result when the body is blank" do
    result = described_class.call("body" => "   ")

    expect(result.failure?).to be(true)
    expect(result.failure.first).to eq(:validation)
    expect(Note.count).to eq(0)
  end
end
RUBY

  cat > "$APP_DIR/spec/requests/notes_spec.rb" <<'RUBY'
# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Notes", type: :request do
  it "lists existing notes" do
    Note.create(body: "a seeded note")

    get "/"

    expect(last_response).to be_ok
    expect(last_response.body).to include("a seeded note")
  end

  it "creates a note and redirects" do
    post "/notes", "body" => "written via request"

    expect(last_response.status).to eq(302)
    expect(Note.where(body: "written via request").count).to eq(1)
  end

  it "re-renders with 422 on invalid input" do
    post "/notes", "body" => ""

    expect(last_response.status).to eq(422)
  end
end
RUBY

  cat > "$APP_DIR/.env.example" <<'ENVX'
# Copy to .env for local dev (dotenv loads it). NEVER commit real secrets.
RACK_ENV=development
PORT=4000
DATABASE_PATH=db/development.sqlite3
# openssl rand -hex 64
SECRET_KEY_BASE=replace-with-a-64-byte-hex-secret
ENVX

  cat > "$APP_DIR/.gitignore" <<'GI'
/db/*.sqlite3
/db/*.sqlite3-shm
/db/*.sqlite3-wal
.env
/tmp
/log
*.log
/coverage
GI

  cat > "$APP_DIR/README.md" <<'MD'
# Notes (Sinatra + Sequel + SQLite)

A minimal, tested Sinatra app scaffolded by `push-button-deploy`. See `CLAUDE.md`
and `.claude/` for the conventions Claude Code follows in this repo.

```bash
bundle install
bundle exec rake db:migrate        # create db/development.sqlite3
bundle exec puma -C config/puma.rb  # http://localhost:4000
bundle exec rspec                   # run the suite
```

Layout:

- `app.rb` — the Sinatra app; thin routes only.
- `app/services/` — service objects (one `#call`, return a dry-monads Result).
- `app/models/` — Sequel models (persistence + invariants).
- `config/database.rb` — the SQLite connection (WAL mode; see `.claude/database.md`).
- `db/migrate/` — Sequel migrations (`rake db:migrate`).
- `spec/` — RSpec (Rack::Test + Capybara).

Deploys via the `push-button-deploy` pipeline: push to `main` → test → build →
migrate (gated) → zero-downtime blue/green swap. SQLite is replicated to object
storage by Litestream.
MD

  log "scaffold: wrote app files, an example Note resource, and an RSpec suite"
}

# ---- 3. skill docs (copy + placeholder rewrite) --------------------------------
inject_docs() {
  mkdir -p "$APP_DIR/.claude"
  cp "$TEMPLATE_DIR/CLAUDE.md" "$APP_DIR/CLAUDE.md"
  local count=0 src
  for src in "$TEMPLATE_DIR"/.claude/*.md; do
    [ -e "$src" ] || continue
    cp "$src" "$APP_DIR/.claude/$(basename "$src")"
    count=$((count + 1))
  done

  # Cloud-environment SessionStart hook, if the template ships one.
  if [ -f "$TEMPLATE_DIR/.claude/cloud-setup.sh" ]; then
    cp "$TEMPLATE_DIR/.claude/cloud-setup.sh" "$APP_DIR/.claude/cloud-setup.sh"
    chmod +x "$APP_DIR/.claude/cloud-setup.sh"
  fi
  [ -f "$TEMPLATE_DIR/.claude/settings.json" ] \
    && cp "$TEMPLATE_DIR/.claude/settings.json" "$APP_DIR/.claude/settings.json"

  find "$APP_DIR/CLAUDE.md" "$APP_DIR/.claude" \
    \( -name '*.md' -o -name 'cloud-setup.sh' \) -type f -print0 \
    | MODULE="$APP_MODULE" APP="$APP_NAME" xargs -0 perl -pi -e \
        's/\QMyApp\E/$ENV{MODULE}/g; s/\Qmy_app\E/$ENV{APP}/g;'

  log "skill docs: placed CLAUDE.md + $count docs, names rewritten to $APP_MODULE/$APP_NAME"
}

if [ -f "$APP_DIR/Gemfile" ]; then
  log "app: $APP_DIR already has a Gemfile — injecting skill docs only (retrofit)"
else
  scaffold
fi
inject_docs
