#!/usr/bin/env ruby
# Parse both providers' real workflow templates; execute npm/build/package gate offline.
require 'yaml'
require 'tmpdir'
require 'fileutils'
ROOT = File.expand_path('..', __dir__)
def check(value, message)
  abort message unless value
end
%w[github gitea].each do |provider|
  path = File.join(ROOT, "app/.#{provider}/workflows/deploy.react.yml")
  workflow = YAML.load_file(path)
  steps = workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps', []) }
  commands = steps.map { |step| step['run'] }.compact
  script = commands.join("\n")
  install = commands.index { |cmd| cmd.match?(/npm ci\b/) }
  test = commands.index { |cmd| cmd.match?(/npm (?:run )?test\b/) }
  build = commands.index { |cmd| cmd.match?(/npm run build\b/) }
  package = commands.index { |cmd| cmd.match?(/tar .* -C dist\b/) }
  check([install, test, build, package].all?, "#{provider}: missing npm ci/test/build/dist package")
  check(install <= test && test <= build && build <= package, "#{provider}: test gate must precede publication")
  check(script.include?('dist/index.html'), "#{provider}: missing dist output validation")
  check(script.include?('publish.sh') && script.include?('upload-edge'), "#{provider}: missing static publication")
  check(!script.match?(/docker (?:build|push)|registry login|npm (?:run )?(?:start|dev)/), "#{provider}: server runtime or registry use")
  check(steps.any? { |step| step.fetch('uses', '').include?('setup-node') }, "#{provider}: missing Node setup")
  node_step = steps.find { |step| step.fetch('uses', '').include?('setup-node') }
  check(node_step.fetch('with', {})['node-version-file'] == '.node-version', "#{provider}: Node version must come from app pin")
  # Run the actual local gate with deterministic npm; failed tests/builds must
  # never produce a publishable archive. SSH/cloud steps are outside this gate.
  gate = commands[install..package].join("\n")
  check(!gate.include?('${{'), "#{provider}: local gate unexpectedly requires CI interpolation")
  Dir.mktmpdir('react-gate') do |dir|
    FileUtils.mkdir_p("#{dir}/bin")
    File.write("#{dir}/bin/npm", <<~SH)
      #!/usr/bin/env bash
      set -eu
      printf '%s\\n' "$*" >> "$EVENTS"
      [ "$*" != "$FAIL_COMMAND" ] || exit 23
      if [ "$*" = 'run build' ] && [ "$NO_OUTPUT" != 1 ]; then mkdir -p dist; printf '<h1>built</h1>' > dist/index.html; fi
    SH
    FileUtils.chmod(0755, "#{dir}/bin/npm")
    %w[none test build missing-output].each do |mode|
      FileUtils.rm_rf("#{dir}/dist")
      Dir.glob("#{dir}/*.tgz").each { |file| File.unlink(file) }
      events = "#{dir}/events"
      File.write(events, '')
      env = {'PATH' => "#{dir}/bin:#{ENV.fetch('PATH')}", 'EVENTS' => events,
             'NO_OUTPUT' => mode == 'missing-output' ? '1' : '0',
             'FAIL_COMMAND' => {'none' => '', 'test' => 'test', 'build' => 'run build', 'missing-output' => ''}.fetch(mode)}
      # Support either npm test or npm run test without constraining script style.
      env['FAIL_COMMAND'] = 'run test' if mode == 'test' && gate.match?(/npm run test/)
      success = system(env, 'bash', '-euo', 'pipefail', '-c', gate, chdir: dir, out: File::NULL, err: File::NULL)
      check(success == (mode == 'none'), "#{provider}: incorrect #{mode} gate status")
      archives = Dir.glob("#{dir}/*.tgz")
      check((mode == 'none') == !archives.empty?, "#{provider}: #{mode} published invalid archive")
      check(!File.read(events).include?('run build'), "#{provider}: build ran after failed test") if mode == 'test'
    end
  end
  rollback = YAML.load_file(File.join(ROOT, "app/.#{provider}/workflows/rollback.zola.yml"))
  check(rollback.fetch('jobs').to_s.include?('publish.sh'), "#{provider}: static rollback missing")
end
puts 'React provider workflows and failing build gates passed'
