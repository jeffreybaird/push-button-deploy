#!/usr/bin/env ruby
# Execute the Rails workflow gate at its local command boundaries, offline.
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'
root = File.expand_path('..', __dir__)
files = %w[app/.github/workflows/deploy.rails.yml app/.gitea/workflows/deploy.rails.yml app/.github/workflows/staging.rails.yml]
files.each do |relative|
  workflow = YAML.load_file(File.join(root, relative))
  gate = workflow.fetch('jobs').fetch('test').fetch('steps').find { |step| step['run'].to_s.include?('bin/check') }
  abort "#{relative}: missing quality gate" unless gate
  script = gate.fetch('run')
  %w[fresh failing nonexecutable legacy].each do |mode|
    Dir.mktmpdir('rails-gate') do |dir|
      FileUtils.mkdir_p(File.join(dir, 'bin'))
      events = File.join(dir, 'events')
      bundle = File.join(dir, 'bin/bundle')
      File.write(bundle, "#!/bin/sh\nprintf 'legacy %s\\n' \"$*\" >> \"$EVENTS\"\n")
      File.chmod(0755, bundle)
      unless mode == 'legacy'
        check = File.join(dir, 'bin/check')
        File.write(check, "#!/bin/sh\necho quality >> \"$EVENTS\"\nexit #{mode == 'failing' ? 17 : 0}\n")
        File.chmod(mode == 'nonexecutable' ? 0644 : 0755, check)
      end
      _, error, status = Open3.capture3({'PATH' => "#{dir}/bin:#{ENV.fetch('PATH')}", 'EVENTS' => events}, 'bash', '-e', '-c', script, chdir: dir)
      lines = File.exist?(events) ? File.readlines(events).map(&:strip) : []
      if %w[failing nonexecutable].include?(mode)
        abort "#{relative}: failed quality gate passed" if status.success?
        abort "#{relative}: failed quality gate fell back" if lines.any? { |line| line.start_with?('legacy') }
      elsif mode == 'fresh'
        abort "#{relative}: quality gate not executed #{error}" unless status.success? && lines == ['quality']
      else
        abort "#{relative}: legacy gate fails #{error}" unless status.success?
        abort "#{relative}: missing legacy database/test check" unless lines == ['legacy exec rails db:prepare', 'legacy exec rails test']
      end
    end
  end
end
puts 'Rails quality and adopted-app workflow gates passed'
# Fresh scaffolds must execute every gate and stop at the first failing one.
Dir.mktmpdir('rails-check') do |dir|
  app = File.join(dir, 'quality_app')
  output, status = Open3.capture2e('bash', File.join(root, 'scripts/new-rails-app.sh'), app)
  abort output unless status.success?
  check_file = File.join(app, 'bin/check')
  abort 'scaffold omitted bin/check' unless File.executable?(check_file)
  mockbin = File.join(dir, 'mockbin')
  FileUtils.mkdir_p(mockbin)
  File.write(File.join(mockbin, 'bundle'), <<~SH)
    #!/bin/sh
    test ! -f coverage/stale-result || exit 98
    test "$RAILS_ENV" = test || exit 99
    test "${DATABASE_PATH+x}" != x || exit 96
    test "${DATABASE_URL+x}" != x || exit 97
    test "${PRIMARY_DATABASE_URL+x}" != x || exit 95
    printf '%s\n' "$*" >> "$EVENTS"
    test "$*" != "$FAIL_GATE" || exit 17
  SH
  File.chmod(0755, File.join(mockbin, 'bundle'))
  expected = ['exec rails db:prepare', 'exec rubocop', 'exec rspec', 'exec cucumber --strict', 'exec ruby script/coverage.rb', 'exec bundler-audit check --update']
  ([''] + expected).each do |failure|
    events = File.join(dir, 'events')
    FileUtils.rm_f(events)
    FileUtils.mkdir_p(File.join(app, 'coverage'))
    File.write(File.join(app, 'coverage/stale-result'), 'old coverage must not pass')
    _, error, status = Open3.capture3({'PATH' => "#{mockbin}:#{ENV.fetch('PATH')}", 'EVENTS' => events, 'FAIL_GATE' => failure, 'RAILS_ENV' => 'production', 'DATABASE_PATH' => '/data/production.sqlite3', 'DATABASE_URL' => 'sqlite3:/data/production.sqlite3', 'PRIMARY_DATABASE_URL' => 'sqlite3:/data/primary.sqlite3'}, check_file, chdir: app)
    actual = File.exist?(events) ? File.readlines(events).map(&:strip) : []
    wanted = failure.empty? ? expected : expected.take(expected.index(failure) + 1)
    abort "quality gate order/early failure mismatch: #{actual.inspect} #{error}" unless actual == wanted
    abort 'quality gate status mismatch' unless status.success? == failure.empty?
  end
end
puts 'Generated Rails bin/check gates execute and fail closed'
