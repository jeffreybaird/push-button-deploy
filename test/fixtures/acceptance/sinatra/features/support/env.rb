# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
ENV.delete("DATABASE_URL")
ENV.delete("PRIMARY_DATABASE_URL")
ENV["DATABASE_PATH"] = File.expand_path("../../db/cucumber.sqlite3", __dir__)

require_relative "../../config/database"
Sequel.extension :migration
Sequel::Migrator.run(DB, File.expand_path("../../db/migrate", __dir__))
require_relative "../../config/environment"
require "rack/test"
require "rspec/expectations"

module AcceptanceRequests
  include Rack::Test::Methods
  include RSpec::Matchers

  def app
    App
  end
end

World(AcceptanceRequests)
Around do |_scenario, block|
  DB.transaction(rollback: :always, savepoint: true) { block.call }
end
