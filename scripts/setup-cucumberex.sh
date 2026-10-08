#!/usr/bin/env bash
# Install acceptance tooling only into a freshly generated Elixir project.
# This is independent of optional documentation and APP_EXTRA_DEPS.
set -euo pipefail
APP_DIR="${1:?usage: setup-cucumberex.sh APP_DIR phoenix|mix|escript}"
KIND="${2:?missing project kind}"
case "$KIND" in phoenix|mix|escript) ;; *) echo "unsupported project kind: $KIND" >&2; exit 1 ;; esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/app-meta.sh"
APP_MODULE="$(app_module "$APP_DIR")"
python3 - "$APP_DIR" <<'PYTHON'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
mixfile = root / "mix.exs"
text = mixfile.read_text()
if not re.search(r"\{:cucumberex,", text):
    text, count = re.subn(r"(defp deps do\s*\[)", r'\1\n      {:cucumberex, "~> 0.2.1", only: [:dev, :test]},', text, count=1)
    if count != 1:
        raise SystemExit("Cannot find fresh project's deps list")
if not re.search(r"\{:protox,", text):
    # cucumber_messages' generated code is incompatible with Protox 2.1.
    text, count = re.subn(r"(defp deps do\s*\[)", r'\1\n      {:protox, "~> 2.0.8", only: [:dev, :test]},', text, count=1)
    if count != 1:
        raise SystemExit("Cannot configure compatible Protox runtime")
if not re.search(r"cucumber:\s*:test", text):
    if "preferred_envs:" in text:
        text, count = re.subn(r"preferred_envs:\s*\[", "preferred_envs: [cucumber: :test, ", text, count=1)
    elif re.search(r"def cli do\s*\[", text):
        text, count = re.subn(r"(def cli do\s*\[)", r"\1preferred_envs: [cucumber: :test], ", text, count=1)
    else:
        text, count = re.subn(r"  defp deps do", "  def cli do\n    [preferred_envs: [cucumber: :test]]\n  end\n\n  defp deps do", text, count=1)
    if count != 1:
        raise SystemExit("Cannot configure fresh project's cucumber test environment")
mixfile.write_text(text)
formatter = root / ".formatter.exs"
text = formatter.read_text()
if "features/**/*.{ex,exs}" not in text:
    text, count = re.subn(r"inputs:\s*\[", 'inputs: ["features/**/*.{ex,exs}", ', text, count=1)
    if count != 1:
        raise SystemExit("Cannot find fresh project's formatter inputs")
if ":cucumberex" not in text:
    if "import_deps:" in text:
        text, count = re.subn(r"import_deps:\s*\[", "import_deps: [:cucumberex, ", text, count=1)
    else:
        text, count = re.subn(r"\[", "[\n  import_deps: [:cucumberex],", text, count=1)
    if count != 1:
        raise SystemExit("Cannot configure fresh project's formatter imports")
def format_inputs(match):
    if len("  " + match.group(0)) <= 98:
        return match.group(0)
    items = re.findall(r'"[^"]*"', match.group(1))
    return "inputs: [\n    " + ",\n    ".join(items) + "\n  ]"

text = re.sub(r"inputs:\s*\[([^\]]*)\]", format_inputs, text)
formatter.write_text(text)
PYTHON
mkdir -p "$APP_DIR/bin" "$APP_DIR/features/support" "$APP_DIR/features/step_definitions"
cat > "$APP_DIR/bin/check-features" <<'ACCEPTANCE'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MIX_ENV=test
exec mix cucumber --format pretty --strict
ACCEPTANCE
chmod +x "$APP_DIR/bin/check-features"
case "$KIND" in
  phoenix)
    sed "s/__APP_MODULE__/$APP_MODULE/g" > "$APP_DIR/features/home.feature" <<'ACCEPTANCE'
Feature: Application home page
  Scenario: Render the application home page
    When I visit the application home page
    Then the application renders its welcome page
ACCEPTANCE
    sed "s/__APP_MODULE__/$APP_MODULE/g" > "$APP_DIR/features/step_definitions/home_steps.ex" <<'ACCEPTANCE'
defmodule __APP_MODULE__.HomeSteps do
  use Cucumberex.DSL
  import ExUnit.Assertions
  import Phoenix.ConnTest

  @endpoint __APP_MODULE__Web.Endpoint

  when_ "I visit the application home page", fn world ->
    Map.put(world, :response, get(build_conn(), "/"))
  end

  then_ "the application renders its welcome page", fn world ->
    assert html_response(world.response, 200) =~ "Peace of mind"
    world
  end
end
ACCEPTANCE
    sed "s/__APP_MODULE__/$APP_MODULE/g" > "$APP_DIR/features/support/env.ex" <<'ACCEPTANCE'
# Acceptance tests must use test-only dependencies and configuration.
unless Mix.env() == :test do
  raise "Run acceptance tests in MIX_ENV=test"
end
ACCEPTANCE
    ;;
  mix)
    sed "s/__APP_MODULE__/$APP_MODULE/g" > "$APP_DIR/features/greeting.feature" <<'ACCEPTANCE'
Feature: Library greetings
  Scenario: Greet a named recipient
    When I greet "Ada"
    Then the greeting is "hello Ada"
ACCEPTANCE
    sed "s/__APP_MODULE__/$APP_MODULE/g" > "$APP_DIR/features/step_definitions/greeting_steps.ex" <<'ACCEPTANCE'
defmodule __APP_MODULE__.GreetingSteps do
  use Cucumberex.DSL
  import ExUnit.Assertions

  when_ "I greet {string}", fn world, recipient ->
    Map.put(world, :greeting, __APP_MODULE__.greet([recipient]))
  end

  then_ "the greeting is {string}", fn world, expected ->
    assert world.greeting == expected
    world
  end
end
ACCEPTANCE
    sed "s/__APP_MODULE__/$APP_MODULE/g" > "$APP_DIR/features/support/env.ex" <<'ACCEPTANCE'
# Acceptance tests must use test-only dependencies and configuration.
unless Mix.env() == :test do
  raise "Run acceptance tests in MIX_ENV=test"
end
ACCEPTANCE
    ;;
  escript)
    sed "s/__APP_MODULE__/$APP_MODULE/g" > "$APP_DIR/features/greeting.feature" <<'ACCEPTANCE'
Feature: Command line greetings
  Scenario: Greet a named recipient successfully
    When I run the greeting command for "Ada"
    Then the command succeeds with "hello Ada"

  Scenario: Reject an unsupported output format
    When I request the unsupported format "xml"
    Then the command reports a usage error
ACCEPTANCE
    sed "s/__APP_MODULE__/$APP_MODULE/g" > "$APP_DIR/features/step_definitions/greeting_steps.ex" <<'ACCEPTANCE'
defmodule __APP_MODULE__.GreetingSteps do
  use Cucumberex.DSL
  import ExUnit.Assertions

  when_ "I run the greeting command for {string}", fn world, recipient ->
    Map.put(world, :result, __APP_MODULE__.CLI.run([recipient]))
  end

  then_ "the command succeeds with {string}", fn world, expected ->
    assert world.result == {expected, 0}
    world
  end

  when_ "I request the unsupported format {string}", fn world, format ->
    Map.put(world, :result, __APP_MODULE__.CLI.run(["--format", format]))
  end

  then_ "the command reports a usage error", fn world ->
    assert {message, 2} = world.result
    assert message =~ "unknown format: xml"
    assert message =~ "Usage:"
    world
  end
end
ACCEPTANCE
    sed "s/__APP_MODULE__/$APP_MODULE/g" > "$APP_DIR/features/support/env.ex" <<'ACCEPTANCE'
# Acceptance tests must use test-only dependencies and configuration.
unless Mix.env() == :test do
  raise "Run acceptance tests in MIX_ENV=test"
end
ACCEPTANCE
    ;;
esac
