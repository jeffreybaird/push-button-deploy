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
