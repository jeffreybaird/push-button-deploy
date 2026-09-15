#!/usr/bin/env ruby
# Parse templates and syntax-check their shell without contacting a provider.
require 'yaml'
require 'open3'
root = File.expand_path('..', __dir__)
files = Dir[File.join(root, 'app/.{github,gitea}/workflows/*.yml')]
checks = 0
files.each do |file|
  workflow = YAML.load_file(file)
  workflow.fetch('jobs').each do |job_name, job|
    commands = []
    job.fetch('steps').each do |step|
      next unless step['run']
      script = step['run']
      _, error, status = Open3.capture3('bash', '-n', stdin_data: script.gsub(/\$\{\{.*?\}\}/m, 'value'))
      abort "#{file}: #{step['name']}: #{error}" unless status.success?
      script.scan(/bash (deploy\/ci\/[\w.-]+\.sh)/).flatten.each do |helper|
        abort "missing helper #{helper}" unless File.file?(File.join(root, helper))
      end
      commands << script
      checks += 1
    end
    commands = commands.join("\n")
    if File.basename(file).start_with?('rollback')
      abort "rollback must not migrate: #{file}" if commands.include?('remote.sh migrate')
    elsif commands.include?('remote.sh swap')
      migrate = commands.index('remote.sh migrate')
      swap = commands.index('remote.sh swap')
      abort "migration must precede swap: #{file}/#{job_name}" unless migrate && migrate < swap
    end
    if File.basename(file).start_with?('staging') && job_name == 'deploy'
      abort 'staging must use its own edge policy' unless commands.include?('remote.sh upload-staging-edge')
      abort 'staging must not replace production edge' if commands.include?('remote.sh upload-edge')
    end
  end
end
abort 'no workflows found' if files.empty?
puts "#{files.length} workflow templates parse; #{checks} shell steps pass syntax and deployment policy checks"
