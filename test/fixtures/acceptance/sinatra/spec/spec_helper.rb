# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
# Isolated, disposable test DB — recreated from migrations before every run.
ENV.delete("DATABASE_URL")
ENV.delete("PRIMARY_DATABASE_URL")
ENV["DATABASE_PATH"] = File.expand_path("../db/test.sqlite3", __dir__)
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
