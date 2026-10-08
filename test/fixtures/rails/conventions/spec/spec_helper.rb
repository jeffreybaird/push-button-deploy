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
