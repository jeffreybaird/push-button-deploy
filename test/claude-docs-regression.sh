#!/usr/bin/env bash
# Ownership, rerun, literal rendering and preflight failure contracts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/test/helpers/assertions.sh"
log() { :; }
. "$ROOT/scripts/claude-docs.sh"
assert_not declare -F ask_yesno
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TEMPLATE="$WORK/template"
APP="$WORK/app with spaces"
mkdir -p "$TEMPLATE/.claude/agents" "$APP/doc/agents" "$APP/.claude"
cat > "$TEMPLATE/claude-docs.manifest" <<'MANIFEST'
placeholders|MyApp|my_app
optional|optional.md|Optional guidance
agent|reviewer.md|Review agent
hook|format|Formatter
MANIFEST
cat > "$TEMPLATE/CLAUDE.md" <<'DOC'
MyApp my_app MyAppWeb :my_app
- `.claude/core.md` — core
- `.claude/optional.md` — optional
Prose mentioning `.claude/optional.md` stays.
DOC
printf 'MyApp my_app\n' > "$TEMPLATE/.claude/core.md"
printf 'MyApp my_app\n' > "$TEMPLATE/.claude/optional.md"
printf 'MyApp my_app\n' > "$TEMPLATE/.claude/agents/reviewer.md"
printf '#!/bin/bash\n# my_app\n' > "$TEMPLATE/.claude/cloud-setup.sh"
printf '{"plain":true}\n' > "$TEMPLATE/.claude/settings.json"
printf '{"format":true}\n' > "$TEMPLATE/.claude/settings.format-hook.json"
printf 'MyApp my_app custom notes\n' > "$APP/doc/custom.md"
printf 'MyApp my_app custom agent\n' > "$APP/doc/agents/custom.md"
cp "$APP/doc/custom.md" "$WORK/custom.before"
cp "$APP/doc/agents/custom.md" "$WORK/agent.before"
printf 'MyApp legacy guide\n' > "$APP/CLAUDE.md"
printf 'my_app legacy module\n' > "$APP/.claude/legacy.md"
cp "$APP/.claude/legacy.md" "$WORK/legacy-module"
cd_inject "$TEMPLATE" "$APP" CoolApp cool_app
grep -q CoolApp "$APP/CLAUDE.md"
grep -q '`.claude/core.md`' "$APP/CLAUDE.md"
cmp "$WORK/legacy-module" "$APP/.claude/legacy.md"
cmp "$WORK/custom.before" "$APP/doc/custom.md"
cmp "$WORK/agent.before" "$APP/doc/agents/custom.md"
[ -x "$APP/doc/hooks/cloud-setup.sh" ]
cp -R "$APP" "$WORK/first"
cd_inject "$TEMPLATE" "$APP" CoolApp cool_app
diff -r "$WORK/first" "$APP"

# Skipping on a rerun preserves existing content, even former generated files.
printf 'MyApp edited optional\n' > "$APP/doc/optional.md"
printf 'MyApp edited agent\n' > "$APP/doc/agents/reviewer.md"
printf '{"custom":true}\n' > "$APP/.claude/settings.json"
printf '# my_app custom setup\n' > "$APP/doc/hooks/cloud-setup.sh"
cp -R "$APP/doc" "$WORK/skipped"
cp "$APP/.claude/settings.json" "$WORK/skipped-settings"
CD_SKIP_MODULES=optional.md CD_SKIP_AGENTS=reviewer.md CD_NO_SETUP=1 \
  cd_inject "$TEMPLATE" "$APP" CoolApp cool_app
diff -r "$WORK/skipped" "$APP/doc"
cmp "$WORK/skipped-settings" "$APP/.claude/settings.json"
assert_not grep -q '^-.*optional.md' "$APP/AGENTS.md"
assert_not grep -q '^-.*optional.md' "$APP/CLAUDE.md"
grep -q 'Prose mentioning' "$APP/AGENTS.md"

# Values are literal, including characters meaningful to Perl replacements;
# inserted placeholder-like text must not be processed a second time.
cd_inject "$TEMPLATE" "$APP" 'my_app$&/Name' 'real$&/app'
printf '%s\n' 'my_app$&/Name real$&/app my_app$&/NameWeb :real$&/app' > "$WORK/expected"
head -n 1 "$APP/AGENTS.md" > "$WORK/actual"
cmp "$WORK/expected" "$WORK/actual"
CD_HOOK=format cd_inject "$TEMPLATE" "$APP" CoolApp cool_app
cmp "$TEMPLATE/.claude/settings.format-hook.json" "$APP/.claude/settings.json"
assert_not test -e "$APP/doc/settings.format-hook.json"

# Invalid selections fail before modifying any existing file.
cp -R "$APP" "$WORK/before-error"
assert_not bash -c '. "$1/scripts/claude-docs.sh"; CD_HOOK=missing; cd_inject "$2" "$3" Changed changed' _ "$ROOT" "$TEMPLATE" "$APP"
diff -r "$WORK/before-error" "$APP"

# Links at a selected file or a docs directory must never redirect writes.
for target in CLAUDE.md AGENTS.md doc/core.md doc/agents doc/hooks doc .claude .claude/agents; do
  dest="$WORK/link-case"
  rm -rf "$dest"
  cp -R "$APP" "$dest"
  rm -rf "$dest/$target"
  ln -s "$WORK/before-error" "$dest/$target"
  assert_not bash -c '. "$1/scripts/claude-docs.sh"; cd_inject "$2" "$3" Changed changed' _ "$ROOT" "$TEMPLATE" "$dest"
  diff -r "$WORK/before-error" "$APP"
done

# Declining the final hook question is a successful guided selection.
ask_yesno() { REPLY_VALUE=true; case "$1" in *"also add"*) REPLY_VALUE=false;; esac; }
cd_prompt_selection "$TEMPLATE"
[ -z "$CD_HOOK" ]
# The public command still resolves and injects a framework without a terminal.
bash "$ROOT/claude-docs.sh" --all --framework zola "$WORK/travel_notes" >/dev/null
[ -f "$WORK/travel_notes/doc/content.md" ]
grep -q 'Travel Notes' "$WORK/travel_notes/AGENTS.md"
# Real framework settings must invoke the relocated executable, including
# paths with spaces. Substitute a harmless script rather than running setup.
for framework in phoenix sinatra; do
  for hook in '' format; do
    target="$WORK/$framework $hook hook"
    CD_HOOK="$hook" cd_inject "$(cd_template_dir "$framework")" "$target" CoolApp cool_app
    [ -f "$target/CLAUDE.md" ]
    [ -f "$target/.claude/agents/test-writer.md" ]
    [ -x "$target/.claude/cloud-setup.sh" ]
    grep -q 'CLAUDE.md' "$target/.claude/agents/test-writer.md"
    assert_not grep -R -E 'CLAUDE\.md|\.claude/' "$target/AGENTS.md" "$target/doc/agents"
    [ -x "$target/doc/hooks/cloud-setup.sh" ]
    cmp "$target/.claude/cloud-setup.sh" "$target/doc/hooks/cloud-setup.sh"
    command="$(jq -er '.hooks.SessionStart[0].hooks[0].command' "$target/.claude/settings.json")"
    printf '#!/bin/bash\nprintf hooked > "$CLAUDE_PROJECT_DIR/hook-ran"\n' > "$target/doc/hooks/cloud-setup.sh"
    CLAUDE_PROJECT_DIR="$target" bash -c "$command"
    [ "$(cat "$target/hook-ran")" = hooked ]
    if [ "$hook" = format ]; then
      jq -e '.hooks.PostToolUse[0].hooks[0].command | test("mix format|rubocop")' "$target/.claude/settings.json" >/dev/null
    fi
  done
  target="$WORK/$framework no hook"
  CD_NO_SETUP=1 cd_inject "$(cd_template_dir "$framework")" "$target" CoolApp cool_app
  assert_not test -e "$target/doc/hooks/cloud-setup.sh"
  assert_not test -e "$target/.claude/settings.json"
done
printf 'docs injection regression checks passed\n'
