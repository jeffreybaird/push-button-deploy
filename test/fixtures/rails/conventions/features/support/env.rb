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
