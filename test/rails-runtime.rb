#!/usr/bin/env ruby
# Offline structural contracts for Rails deploy artifacts; no gems or Docker.
require 'yaml'
root = File.expand_path('..', __dir__)
def check(condition, message)
  abort message unless condition
end
%w[github gitea].each do |provider|
  %w[deploy rollback].each do |kind|
    file = File.join(root, "app/.#{provider}/workflows/#{kind}.rails.yml")
    check(File.file?(file), "missing #{file}")
    workflow = YAML.load_file(file)
    scripts = workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps').map { |s| s['run'].to_s } }.join("\n")
    check(scripts.include?('remote.sh swap'), "#{file}: no swap")
    if kind == 'deploy'
      check(scripts.include?('bin/check'), "#{file}: no Rails quality gate")
      check(scripts.include?('runtime-env.sh sqlite production'), "#{file}: no SQLite runtime environment")
      check(scripts.include?('remote.sh migrate rails'), "#{file}: wrong migration framework")
    else
      check(!scripts.match?(/db:(?:prepare|migrate)|remote.sh migrate/), "#{file}: rollback migrates")
    end
  end
end
file = File.join(root, 'app/.github/workflows/staging.rails.yml')
check(File.file?(file), 'missing Rails staging workflow')
workflow = YAML.load_file(file)
scripts = workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps').map { |s| s['run'].to_s } }.join("\n")
check(scripts.include?('bin/check'), 'Rails staging must run its quality gate')
check(scripts.include?('runtime-env.sh sqlite staging'), 'Rails staging must isolate SQLite environment')
check(scripts.include?('remote.sh migrate rails'), 'Rails staging must prepare its database')
# Existing workflow-templates.rb checks shell syntax, migration ordering and edge isolation.
compose_file = File.join(root, 'deploy/compose.rails.yaml')
compose = if YAML.respond_to?(:unsafe_load_file)
            YAML.unsafe_load_file(compose_file)
          else
            YAML.load_file(compose_file)
          end
%w[app_blue app_green migrate].each do |name|
  service = compose.fetch('services').fetch(name)
  check(service.fetch('volumes').include?('app_data:/data'), "#{name}: missing shared persistent database")
  check(service.fetch('environment')['RAILS_ENV'] == 'production', "#{name}: wrong Rails environment")
  check(service.fetch('environment')['DATABASE_PATH'] == '${DATABASE_PATH}', "#{name}: database path not propagated")
  check(service.fetch('depends_on').fetch('db_init')['condition'] == 'service_completed_successfully', "#{name}: restore must precede startup")
end
%w[app_blue app_green].each do |name|
  health = compose.fetch('services').fetch(name).fetch('healthcheck').fetch('test').join(' ')
  check(health.include?('/health'), "#{name}: wrong health endpoint")
  check(health.include?('200'), "#{name}: healthcheck must require HTTP 200")
end
docker = File.read(File.join(root, 'app/Dockerfile.rails'), encoding: 'UTF-8')
check(docker.match?(/RAILS_ENV[= ]+"?production/), 'Rails Docker runtime must select production')
check(docker.include?('65534'), 'Rails runtime UID must match shared volume owner')
check(docker.include?('puma'), 'Rails Docker runtime must launch Puma')
check(!docker.match?(/^RUN .*db:(?:prepare|migrate)/), 'Docker build must not migrate the production database')
puts 'Rails runtime and workflow contracts passed'
