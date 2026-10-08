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
