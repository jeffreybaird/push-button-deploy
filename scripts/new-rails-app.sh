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
  mkdir -p "$APP_DIR"/{app/controllers,config/environments,db/migrate,bin,test/integration,public,tmp,log}
  printf '%s\n' "${RUBY_VERSION:-3.3.12}" > "$APP_DIR/.ruby-version"
  printf '%s\n' "$APP_NAME" > "$APP_DIR/.app-name"
  cat > "$APP_DIR/Gemfile" <<'RUBY'
source "https://rubygems.org"
ruby file: ".ruby-version"
gem "rails", "~> 8.1.4"
gem "puma", "~> 7.2.1"
gem "sqlite3", "~> 2.6"
# Security floors also override vulnerable Ruby default-gem versions.
gem "resolv", "~> 0.3.2"
gem "erb", ">= 6.0.4"
gem "rails-html-sanitizer", ">= 1.7.1"
RUBY
  cat > "$APP_DIR/config/boot.rb" <<'RUBY'
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"
RUBY
  cat > "$APP_DIR/config/application.rb" <<RUBY
require_relative "boot"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "rails/test_unit/railtie"
Bundler.require(*Rails.groups)

module $APP_MODULE
  class Application < Rails::Application
    config.load_defaults 8.1
    # This service uses one SQLite database. No background workers or Solid
    # Queue/Cache/Cable databases are generated or booted implicitly.
    config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  end
end
RUBY
  cat > "$APP_DIR/config/environment.rb" <<'RUBY'
require_relative "application"
Rails.application.initialize!
RUBY
  cat > "$APP_DIR/config/environments/production.rb" <<'RUBY'
Rails.application.configure do
  config.eager_load = true
  config.enable_reloading = false
  config.consider_all_requests_local = false
  # Image source is immutable; migrations update the volume, not db/schema.rb.
  config.active_record.dump_schema_after_migration = false
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE") { ENV["SECRET_KEY_BASE_DUMMY"] && "build-only-dummy-secret" }
  # Caddy terminates HTTPS; internal Docker readiness probes use plain HTTP.
  config.assume_ssl = true
  config.force_ssl = true
  config.ssl_options = { redirect: { exclude: ->(request) { ["/health", "/up"].include?(request.path) } } }
  config.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))
end
RUBY
  cat > "$APP_DIR/config/environments/development.rb" <<'RUBY'
Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
end
RUBY
  cat > "$APP_DIR/config/environments/test.rb" <<'RUBY'
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
max_threads = Integer(ENV.fetch("RAILS_MAX_THREADS", 5))
threads 1, max_threads
bind "tcp://0.0.0.0:#{ENV.fetch('PORT', 4000)}"
environment ENV.fetch("RAILS_ENV", "development")
RUBY
  cat > "$APP_DIR/config/routes.rb" <<'RUBY'
Rails.application.routes.draw do
  get "/health", to: "health#show"
  get "/up", to: "health#show"
  root "health#show"
end
RUBY
  cat > "$APP_DIR/app/controllers/application_controller.rb" <<'RUBY'
class ApplicationController < ActionController::Base
end
RUBY
  cat > "$APP_DIR/app/controllers/health_controller.rb" <<'RUBY'
class HealthController < ApplicationController
  def show
    ActiveRecord::Base.connection.execute("SELECT 1")
    render json: { status: "ok" }
  end
end
RUBY
  cat > "$APP_DIR/config.ru" <<'RUBY'
require_relative "config/environment"
run Rails.application
Rails.application.load_server
RUBY
  cat > "$APP_DIR/Rakefile" <<'RUBY'
require_relative "config/application"
Rails.application.load_tasks
RUBY
  cat > "$APP_DIR/bin/rails" <<'RUBY'
#!/usr/bin/env ruby
APP_PATH = File.expand_path("../config/application", __dir__)
require_relative "../config/boot"
require "rails/commands"
RUBY
  chmod +x "$APP_DIR/bin/rails"
  cat > "$APP_DIR/test/test_helper.rb" <<'RUBY'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'
RUBY
  cat > "$APP_DIR/test/integration/health_test.rb" <<'RUBY'
require 'test_helper'

class HealthTest < ActionDispatch::IntegrationTest
  test 'health endpoint responds successfully' do
    get '/health'
    assert_response :success
  end
end
RUBY
  cat > "$APP_DIR/.gitignore" <<'IGNORE'
/.bundle
/vendor/bundle
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

A minimal Rails application using Active Record, SQLite and Puma.

```sh
bundle install
bin/rails db:prepare
bin/rails server -b 0.0.0.0 -p 4000
bin/rails test
```

`GET /health` returns HTTP 200 when the database is reachable. Production uses
`SECRET_KEY_BASE`, `DATABASE_PATH=/data/app.db` and `PORT=4000`. SQLite WAL is
replicated by Litestream. Deploy migrations run `bundle exec rails db:prepare`
before the healthy blue/green container receives traffic. Keep migrations
compatible with the previous release; image rollback does not undo migrations.

No Solid Queue, Solid Cache or Solid Cable services/databases are configured.
Add background jobs, extra databases or JavaScript build tooling deliberately,
with corresponding deployment and backup changes. See `AGENTS.md` and `doc/`.
MD
fi
# Existing Rails application source stays intact; docs are lifecycle-managed.
. "$SCRIPT_DIR/claude-docs.sh"
cd_inject "$SCRIPT_DIR/../app-template-rails" "$APP_DIR" "$APP_MODULE" "$APP_NAME"
