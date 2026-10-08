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
