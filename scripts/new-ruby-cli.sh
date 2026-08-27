#!/usr/bin/env bash
#
# new-ruby-cli.sh — scaffold a Ruby command-line program in the standard gem
# layout. Invoked by bootstrap.sh's ensure_app for APP_TYPE=cli, LANGUAGE=ruby
# (`./bootstrap.sh --cli ruby <dir>`); also runnable by hand.
#
#   ./scripts/new-ruby-cli.sh <app_dir>
#
# THE SHAPE: a library with an executable on top of it, not a script.
#
#   lib/<name>.rb           the library — where the work happens
#   lib/<name>/cli.rb       argument parsing, and nothing else
#   exe/<name>              a three-line entry point (the gemspec's bindir)
#
# `exe/<name>` is what `gem install` puts on your PATH, so the same code is both
# `require "<name>"` from another program and `<name> --format json` from a
# shell. The CLI layer only parses and prints; every decision worth testing is
# in the library, and the specs call it directly.
#
# ARGUMENTS ARE ARGUMENTS. The CLI is built on OptionParser (stdlib): real long
# and short flags, `--flag value` and `--flag=value`, `--help`, `--version`,
# positional arguments, and exit codes. Nothing is configured by exporting an
# environment variable in front of the command.
#
# WHY PURE BASH, with no `gem`/`bundle` involved: the same reason
# new-sinatra-app.sh and new-zola-site.sh are — the scaffold is written by hand
# and the build runs in CI, so `./bootstrap.sh --cli ruby` needs no local Ruby.
#
# What it writes is `rubocop`-agnostic but conventionally formatted, and the
# specs pass as emitted — CI runs them on the first push.
#
# Ruby version comes from RUBY_VERSION, else the same default the Sinatra
# scaffold pins.
#
# If <app_dir> already contains a Gemfile it is left alone.
#
# Portable: BSD/macOS bash, awk.
set -euo pipefail

fail() { printf 'new-ruby-cli: %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }

APP_DIR="${1:-}"
[ -n "$APP_DIR" ] || fail "usage: new-ruby-cli.sh <app_dir>"

APP_NAME="$(basename "$APP_DIR")"
case "$APP_NAME" in
  [a-z]*[!a-z0-9_]*|*[!a-z0-9_]*|[!a-z]*)
    fail "app name '$APP_NAME' must be lower_snake_case (start with a letter): the dir basename names the gem and the executable" ;;
esac
APP_MODULE="$(printf '%s' "$APP_NAME" | awk -F_ '{o=""; for(i=1;i<=NF;i++){o=o toupper(substr($i,1,1)) substr($i,2)} print o}')"
RUBY_PIN="${RUBY_VERSION:-3.3.6}"

if [ -f "$APP_DIR/Gemfile" ]; then
  log "Gemfile already in $APP_DIR — leaving it alone"
  exit 0
fi
[ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ] \
  && fail "$APP_DIR is not empty and has no Gemfile — refusing to scaffold over it"

log "scaffolding Ruby CLI '$APP_NAME' ($APP_MODULE) in $APP_DIR — ruby $RUBY_PIN"
mkdir -p "$APP_DIR/lib/$APP_NAME" "$APP_DIR/exe" "$APP_DIR/spec"

printf '%s\n' "$RUBY_PIN" > "$APP_DIR/.ruby-version"
printf '%s\n' "$APP_NAME" > "$APP_DIR/.app-name"

cat > "$APP_DIR/.gitignore" <<'EOF'
/.bundle/
/vendor/bundle/
/pkg/
/coverage/
/tmp/
*.gem
.env
EOF

cat > "$APP_DIR/Gemfile" <<'EOF'
# frozen_string_literal: true

source "https://rubygems.org"

# The gemspec is the source of truth for runtime dependencies; the Gemfile only
# adds what developing the gem needs.
gemspec

group :development, :test do
  gem "rake", "~> 13.2"
  gem "rspec", "~> 3.13"
end
EOF

cat > "$APP_DIR/${APP_NAME}.gemspec" <<EOF
# frozen_string_literal: true

require_relative "lib/$APP_NAME/version"

Gem::Specification.new do |spec|
  spec.name    = "$APP_NAME"
  spec.version = $APP_MODULE::VERSION
  spec.authors = ["TODO"]
  spec.summary = "TODO: one sentence describing $APP_NAME."
  spec.license = "MIT"

  spec.required_ruby_version = ">= ${RUBY_PIN%.*}"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md"]

  # This is what makes the library runnable as a command: \`gem install $APP_NAME\`
  # puts exe/$APP_NAME on the PATH as \`$APP_NAME\`.
  spec.bindir      = "exe"
  spec.executables = ["$APP_NAME"]

  # Argument parsing is OptionParser, which is stdlib — no runtime dependency.
end
EOF

cat > "$APP_DIR/Rakefile" <<'EOF'
# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)
task default: :spec
EOF

cat > "$APP_DIR/.rspec" <<'EOF'
--require spec_helper
--format documentation
EOF

# ---- the executable --------------------------------------------------------------
# Deliberately three lines: everything it could do belongs somewhere testable.
cat > "$APP_DIR/exe/$APP_NAME" <<EOF
#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/$APP_NAME"

exit $APP_MODULE::CLI.new.run(ARGV)
EOF
chmod +x "$APP_DIR/exe/$APP_NAME"

# ---- the library -----------------------------------------------------------------
cat > "$APP_DIR/lib/$APP_NAME.rb" <<EOF
# frozen_string_literal: true

require_relative "$APP_NAME/version"
require_relative "$APP_NAME/cli"

# $APP_MODULE — replace this with what the tool actually does.
#
# Keep the work in here, in plain methods that take arguments and return values.
# The CLI is a thin translation layer over this module, which is what lets the
# same code be both \`require "$APP_NAME"\` and \`$APP_NAME --format json\`.
module $APP_MODULE
  class Error < StandardError; end

  # An example of the shape: takes what it needs, returns a String, knows
  # nothing about ARGV, \$stdout or exit codes.
  #
  #   $APP_MODULE.greet(["world"], format: :text)  #=> "hello world"
  #
  def self.greet(words, format: :text)
    subject = words.empty? ? "world" : words.join(" ")
    case format
    when :text then "hello #{subject}"
    when :json then %({"greeting":"hello","subject":"#{subject}"})
    else raise Error, "unknown format: #{format}"
    end
  end
end
EOF

cat > "$APP_DIR/lib/$APP_NAME/version.rb" <<EOF
# frozen_string_literal: true

module $APP_MODULE
  VERSION = "0.1.0"
end
EOF

cat > "$APP_DIR/lib/$APP_NAME/cli.rb" <<EOF
# frozen_string_literal: true

require "optparse"

module $APP_MODULE
  # Argument parsing, and nothing else.
  #
  # \`run\` returns an exit status rather than calling \`exit\`, and writes through
  # the streams it was given rather than \$stdout/\$stderr directly — which is
  # what lets the specs drive it with StringIO and assert on both.
  class CLI
    def initialize(out: \$stdout, err: \$stderr)
      @out = out
      @err = err
    end

    # @return [Integer] the process exit status
    def run(argv)
      options = { format: :text }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: $APP_NAME [options] [words...]"
        opts.separator ""
        opts.separator "Options:"

        # A real option with a real value: \`--format json\` and \`--format=json\`
        # both work, and an unacceptable value is rejected by OptionParser.
        opts.on("-f", "--format FORMAT", %w[text json],
                "Output format: text (default) or json") do |value|
          options[:format] = value.to_sym
        end

        opts.on("-h", "--help", "Print this message") do
          @out.puts opts
          return 0
        end

        opts.on("-v", "--version", "Print the version") do
          @out.puts "$APP_NAME #{VERSION}"
          return 0
        end
      end

      words = parser.parse(argv)
      @out.puts $APP_MODULE.greet(words, format: options[:format])
      0
    rescue OptionParser::ParseError => e
      # Exit 2 for a usage error, the convention every shell tool follows:
      # distinguishable from "ran fine" (0) and "ran and failed" (1).
      @err.puts e.message
      @err.puts parser
      2
    rescue $APP_MODULE::Error => e
      @err.puts "$APP_NAME: #{e.message}"
      1
    end
  end
end
EOF

# ---- specs -----------------------------------------------------------------------
cat > "$APP_DIR/spec/spec_helper.rb" <<EOF
# frozen_string_literal: true

require "stringio"
require "$APP_NAME"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
EOF

cat > "$APP_DIR/spec/${APP_NAME}_spec.rb" <<EOF
# frozen_string_literal: true

RSpec.describe $APP_MODULE do
  it "greets the words it is given" do
    expect(described_class.greet(%w[hi there])).to eq("hello hi there")
  end

  it "defaults to the world" do
    expect(described_class.greet([])).to eq("hello world")
  end

  it "renders json" do
    expect(described_class.greet(%w[you], format: :json))
      .to eq(%({"greeting":"hello","subject":"you"}))
  end

  it "refuses a format it does not know" do
    expect { described_class.greet([], format: :yaml) }.to raise_error(described_class::Error)
  end
end
EOF

cat > "$APP_DIR/spec/cli_spec.rb" <<EOF
# frozen_string_literal: true

RSpec.describe $APP_MODULE::CLI do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  subject(:cli) { described_class.new(out: out, err: err) }

  it "prints usage for --help and exits 0" do
    expect(cli.run(["--help"])).to eq(0)
    expect(out.string).to include("Usage: $APP_NAME")
  end

  it "prints the version for --version" do
    expect(cli.run(["--version"])).to eq(0)
    expect(out.string).to include($APP_MODULE::VERSION)
  end

  it "takes an option value with a space" do
    expect(cli.run(["--format", "json", "you"])).to eq(0)
    expect(out.string).to include(%("subject":"you"))
  end

  it "takes an option value with an equals sign" do
    expect(cli.run(["--format=json", "you"])).to eq(0)
    expect(out.string).to include(%("subject":"you"))
  end

  it "accepts the short flag" do
    expect(cli.run(["-f", "json"])).to eq(0)
    expect(out.string).to include(%("subject":"world"))
  end

  it "passes positional arguments through" do
    expect(cli.run(%w[hi there])).to eq(0)
    expect(out.string.chomp).to eq("hello hi there")
  end

  it "exits 2 on an unknown option, and says which" do
    expect(cli.run(["--nope"])).to eq(2)
    expect(err.string).to include("--nope")
  end

  it "exits 2 on an unacceptable option value" do
    expect(cli.run(["--format", "yaml"])).to eq(2)
    expect(err.string).to include("yaml")
  end
end
EOF

cat > "$APP_DIR/README.md" <<EOF
# $APP_NAME

TODO: one sentence describing $APP_NAME.

## Run it

    bundle install
    bundle exec exe/$APP_NAME --help
    bundle exec exe/$APP_NAME --format json hello there

Installed (\`gem install $APP_NAME\`, or \`rake install\` from a checkout) the
executable is on your PATH as \`$APP_NAME\`:

    $APP_NAME --format json hello there

## Shape

\`lib/$APP_NAME.rb\` is a library: plain methods that take arguments and return
values. \`lib/$APP_NAME/cli.rb\` is the only part that knows about \`ARGV\`, and
\`exe/$APP_NAME\` is three lines. So the same code is both \`require "$APP_NAME"\`
from another program and a command in a shell — and the specs test the library
directly rather than through the process.

## Develop

    bundle install
    bundle exec rspec

## Pipeline

Every push runs \`.github/workflows/ci.yml\` (or \`.gitea/workflows/ci.yml\`):
the specs, plus a smoke test of the built executable.

This project provisions no infrastructure — no droplet, no DNS, no database.
It was created with \`pbd bootstrap --cli ruby\`.
EOF

log "scaffolded $APP_DIR (ruby cli): exe/$APP_NAME, lib/, spec/, ${APP_NAME}.gemspec"
