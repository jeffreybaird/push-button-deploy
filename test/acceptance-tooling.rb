#!/usr/bin/env ruby
# Offline scaffold and CI command-boundary contracts for mandatory acceptance tests.
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'yaml'
ROOT = File.expand_path('..', __dir__)
FIXTURES = File.join(ROOT, 'test/fixtures/acceptance')

def read_utf8(path)
  File.read(path, encoding: Encoding::UTF_8)
end

def run!(*command, **options)
  output, status = Open3.capture2e(*command, **options)
  abort "#{command.inspect}: #{output}" unless status.success?
  output
end

def assert(condition, message)
  abort message unless condition
end

Dir.mktmpdir('acceptance-scaffolds') do |work|
  %w[sinatra mix escript phoenix].each do |kind|
    app = File.join(work, kind, 'acceptance_app')
    FileUtils.mkdir_p(File.dirname(app))
    environment = {'APP_EXTRA_DEPS' => '', 'CD_NO_SETUP' => '1'}
    if kind == 'phoenix'
      FileUtils.mkdir_p(app)
      File.write(File.join(app, 'mix.exs'), <<~ELIXIR)
        defmodule AcceptanceApp.MixProject do
          use Mix.Project
          def project do
            [app: :acceptance_app, version: "0.1.0", elixir: "~> 1.15", deps: deps()]
          end
          defp deps do
            [{:phoenix, "~> 1.8"}]
          end
        end
      ELIXIR
      File.write(File.join(app, '.formatter.exs'), '[inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]]')
      run!(environment, 'bash', File.join(ROOT, 'scripts/setup-cucumberex.sh'), app, kind)
      assert(read_utf8(File.join(ROOT, 'scripts/bootstrap/app.sh')).include?('setup-cucumberex.sh'), 'fresh Phoenix bootstrap omits mandatory acceptance setup')
    else
      command = kind == 'sinatra' ? ['scripts/new-sinatra-app.sh'] : ['scripts/new-mix-app.sh', kind == 'mix' ? '--lib' : '--escript']
      command[0] = File.join(ROOT, command[0])
      run!(environment, 'bash', *command, app)
    end
    Dir.glob(File.join(FIXTURES, kind, '**', '*')).select { |path| File.file?(path) }.each do |fixture|
      relative = fixture.sub(File.join(FIXTURES, kind) + '/', '')
      expected = read_utf8(fixture).gsub('__APP_MODULE__', 'AcceptanceApp')
      actual = File.join(app, relative)
      assert(File.file?(actual), "#{kind}: omitted #{relative}")
      assert(read_utf8(actual) == expected, "#{kind}: #{relative} differs from accepted behavior fixture")
    end
    dependency = read_utf8(File.join(app, kind == 'sinatra' ? 'Gemfile' : 'mix.exs'))
    if kind == 'sinatra'
      assert(dependency.match?(/gem ["']cucumber["']/), 'Sinatra lacks actual Cucumber dependency')
      assert(dependency.match?(/gem ["']rspec["']/), 'Sinatra lost RSpec')
    else
      assert(dependency.match?(/\{:cucumberex,\s*"~> 0\.2\.1"/), "#{kind}: missing published Cucumberex dependency")
      cucumber_dependency = dependency[/\{:cucumberex,[^}]*\}/]
      assert(cucumber_dependency.match?(/only:\s*\[:dev,\s*:test\]/), "#{kind}: Cucumberex must stay outside production")
      assert(!cucumber_dependency.match?(/runtime:\s*false/), "#{kind}: Cucumberex application must start its registry")
      assert(dependency.match?(/\{:protox,\s*"~> 2\.0\.8",\s*only:\s*\[:dev,\s*:test\]\s*\}/), "#{kind}: missing compatible dev/test Protox constraint")
      assert(!dependency.match?(/\{:protox,[^}]*override:\s*true/), "#{kind}: Protox must intersect upstream constraints")
      assert(dependency.match?(/cucumber:\s*:test/), "#{kind}: plain mix cucumber does not select test environment")
      formatter = read_utf8(File.join(app, '.formatter.exs'))
      assert(formatter.include?('features/**/*.{ex,exs}') && formatter.include?(':cucumberex'), "#{kind}: feature DSL omitted from formatting")
    end
    gate = File.join(app, 'bin/check-features')
    assert(File.executable?(gate), "#{kind}: missing executable mandatory gate")
    mock = File.join(work, 'mock-' + kind)
    FileUtils.mkdir_p(mock)
    executable = kind == 'sinatra' ? 'bundle' : 'mix'
    File.write(File.join(mock, executable), <<~SH)
      #!/bin/sh
      test "${#{kind == 'sinatra' ? 'RACK_ENV' : 'MIX_ENV'}}" = test || exit 98
      printf '%s\n' "$*" > "$EVENTS"
      exit "$GATE_STATUS"
    SH
    File.chmod(0755, File.join(mock, executable))
    [0, 17].each do |exit_code|
      events = File.join(mock, 'events')
      _, status = Open3.capture2e({'PATH' => mock + ':' + ENV.fetch('PATH'), 'EVENTS' => events,
                                 'GATE_STATUS' => exit_code.to_s, 'RACK_ENV' => 'production', 'MIX_ENV' => 'prod'}, gate, chdir: app)
      expected = kind == 'sinatra' ? 'exec cucumber --format pretty --strict' : 'cucumber --format pretty --strict'
      assert(read_utf8(events).strip == expected, "#{kind}: non-strict or wrong acceptance command")
      assert(status.exitstatus == exit_code, "#{kind}: feature failures were hidden")
    end
  end
end

# Manual documentation injection keeps its documented optional dependency policy.
Dir.mktmpdir('acceptance-manual-injection') do |work|
  {'default' => nil, 'custom' => '{:jason, "~> 1.4"}', 'empty' => ''}.each do |mode, selection|
    app = File.join(work, mode, 'acceptance_app')
    FileUtils.mkdir_p(app)
    File.write(File.join(app, 'mix.exs'), <<~ELIXIR)
      defmodule AcceptanceApp.MixProject do
        use Mix.Project
        def project, do: [app: :acceptance_app, deps: deps()]
        defp deps do
          [
            {:phoenix, "~> 1.8"},
          ]
        end
      end
    ELIXIR
    command = [{'APP_EXTRA_DEPS' => selection, 'CD_NO_SETUP' => '1'}, 'bash',
               File.join(ROOT, 'scripts/inject-skill-docs.sh'), app]
    run!(*command)
    dependencies = read_utf8(File.join(app, 'mix.exs'))
    if mode == 'default'
      ['{:req, "~> 0.5"}', '{:oban, "~> 2.19"}',
       '{:cucumberex, "~> 0.2.1", only: [:dev, :test]}',
       '{:protox, "~> 2.0.8", only: [:dev, :test]}'].each do |dependency|
        assert(dependencies.include?(dependency), "manual injection omitted #{dependency}")
      end
    else
      assert(!dependencies.match?(/\{:(?:req|oban|cucumberex|protox),/), "manual #{mode} injection ignored APP_EXTRA_DEPS")
      assert(dependencies.include?(selection), 'manual custom dependency missing') unless selection.empty?
    end
    run!(*command)
    assert(dependencies == read_utf8(File.join(app, 'mix.exs')), 'manual injection duplicated dependencies on rerun')
  end
end

workflows = %w[deploy.ruby.yml deploy.yml ci.escript.yml ci.mix.yml].flat_map do |name|
  %w[github gitea].map { |provider| "app/.#{provider}/workflows/#{name}" }
end + %w[app/.github/workflows/staging.ruby.yml app/.github/workflows/staging.yml]
workflows.each do |relative|
  data = YAML.load_file(File.join(ROOT, relative))
  jobs = data.fetch('jobs')
  steps = jobs.values.flat_map { |job| job.fetch('steps', []) }
  scripts = steps.map { |step| step['run'].to_s }
  gate = scripts.find { |script| script.include?('bin/check-features') }
  assert(gate, "#{relative}: omitted mandatory feature gate")
  unit = relative.include?('.ruby.') ? 'bundle exec rspec' : 'mix test'
  unit_index = scripts.index { |script| script.include?(unit) }
  assert(unit_index && unit_index <= scripts.index(gate), "#{relative}: lost normal unit gate before feature gate")
  %w[success failure nonexecutable legacy].each do |mode|
    Dir.mktmpdir('acceptance-ci') do |app|
      FileUtils.mkdir_p(File.join(app, 'bin'))
      unless mode == 'legacy'
        File.write(File.join(app, 'bin/check-features'), "#!/bin/sh\necho executed\nexit #{mode == 'failure' ? 17 : 0}\n")
        File.chmod(mode == 'nonexecutable' ? 0644 : 0755, File.join(app, 'bin/check-features'))
      end
      output, status = Open3.capture2e('bash', '-e', '-c', gate, chdir: app)
      assert(status.success? == %w[success legacy].include?(mode), "#{relative}: #{mode} gate did not fail closed")
      if mode == 'legacy'
        assert(output.match?(/legacy/i) && output.match?(/not installed/i), "#{relative}: missing explicit legacy tooling explanation")
      elsif mode != 'nonexecutable'
        assert(output.include?('executed'), "#{relative}: ignored present gate")
      end
    end
  end
end
puts 'Mandatory acceptance scaffolds and all provider gates verified'
