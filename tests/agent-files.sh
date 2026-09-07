#!/usr/bin/env bash
# Offline integration tests; only writes disposable fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TMP="$(mktemp -d "$TEST_TMP_ROOT/agent-files.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
unset APP_AGENTS APP_EXTRA_DEPS
INSTALL="$ROOT/scripts/install-agent-files.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -qF -- "$2" "$1" || fail "$1 missing $2"; }
reject() { if "$@" > "$TMP/error" 2>&1; then fail "unexpected success: $*"; fi; }
fixture() {
  mkdir -p "$1"
  case "$2" in
    phoenix) cat > "$1/mix.exs" <<'MIX'
defmodule AcmeShop.MixProject do
  def project, do: [app: :acme_shop]
  defp deps do
    [
      {:phoenix, "~> 1.8"},
    ]
  end
end
MIX
      ;;
    sinatra) echo 'source "https://rubygems.org"' > "$1/Gemfile" ;;
    zola) echo 'title = "My Site"' > "$1/config.toml" ;;
  esac
}
for framework in phoenix sinatra zola; do
  for agents in claude codex both; do
    dir="$TMP/${framework}_${agents}"
    fixture "$dir" "$framework"
    "$INSTALL" --agents "$agents" "$dir" > "$TMP/log"
    if [ "$agents" != codex ]; then
      [ -f "$dir/CLAUDE.md" ] || fail 'missing Claude instructions'
      [ -f "$dir/.claude/deployment.md" ] || fail 'missing Claude guide'
      if [ "$framework" != zola ]; then
        [ -x "$dir/.claude/cloud-setup.sh" ] || fail 'hook not executable'
        contains "$dir/.claude/settings.json" 'SessionStart'
      fi
    else
      [ ! -e "$dir/.claude" ] && [ ! -e "$dir/CLAUDE.md" ] || fail 'unexpected Claude output'
    fi
    if [ "$agents" != claude ]; then
      [ -f "$dir/AGENTS.md" ] || fail 'missing Codex instructions'
      [ -f "$dir/.agents/skills/deployment/SKILL.md" ] || fail 'missing Codex skill'
      if grep -RE 'Claude|CLAUDE|\.claude|\$ARGUMENTS' "$dir/AGENTS.md" "$dir/.agents"; then fail 'Claude syntax in Codex output'; fi
      for skill in "$dir"/.agents/skills/*/SKILL.md; do
        contains "$skill" "name: $(basename "$(dirname "$skill")")"
        contains "$skill" "description: '"
        [ "$(head -1 "$skill")" = --- ] || fail 'missing front matter'
      done
      if [ "$framework" = phoenix ]; then
        contains "$dir/AGENTS.md" AcmeShop
        contains "$dir/AGENTS.md" '$a11y-audit'
      fi
    else
      [ ! -e "$dir/.agents" ] && [ ! -e "$dir/AGENTS.md" ] || fail 'unexpected Codex output'
    fi
    "$INSTALL" --agents "$agents" "$dir" > "$TMP/log"
    contains "$TMP/log" 'identical'
  done
done
# Files-only report and opt-out; check byte equality of the app signature.
fixture "$TMP/original" phoenix
cmp "$TMP/original/mix.exs" "$TMP/phoenix_both/mix.exs" || fail 'retrofit mutated mix.exs'
"$INSTALL" --agents codex "$TMP/original" > "$TMP/log"
contains "$TMP/log" '{:req,'
contains "$TMP/log" '{:oban,'
contains "$TMP/log" '{:cucumberex,'
APP_EXTRA_DEPS='' "$INSTALL" --agents codex "$TMP/original" > "$TMP/log"
if grep -q 'missing dependencies' "$TMP/log"; then fail 'opt-out ignored'; fi
APP_EXTRA_DEPS='{:custom, "~> 1.0"}' "$INSTALL" --agents codex "$TMP/original" > "$TMP/log"
contains "$TMP/log" '{:custom,'
# Preservation, force isolation, unrelated files, and placeholder safety.
dir="$TMP/phoenix_both"
printf 'custom MyApp guide\n' > "$dir/.claude/custom.md"
printf 'user instructions MyApp\n' > "$dir/CLAUDE.md"
printf 'custom Codex\n' > "$dir/AGENTS.md"
"$INSTALL" --agents both "$dir" > "$TMP/log"
contains "$TMP/log" 'preserved differing CLAUDE.md'
contains "$dir/CLAUDE.md" 'user instructions MyApp'
"$INSTALL" --agents codex --force "$dir" > "$TMP/log"
contains "$dir/CLAUDE.md" 'user instructions MyApp'
contains "$dir/.claude/custom.md" 'custom MyApp guide'
contains "$dir/AGENTS.md" AcmeShop
# Executable hook drift is preserved by default and repairable with force.
chmod -x "$dir/.claude/cloud-setup.sh"
"$INSTALL" --agents claude "$dir" > "$TMP/log"
[ ! -x "$dir/.claude/cloud-setup.sh" ] || fail 'changed hook permissions without force'
"$INSTALL" --agents claude --force "$dir" > "$TMP/log"
[ -x "$dir/.claude/cloud-setup.sh" ] || fail 'force did not restore hook permissions'
# A path containing spaces works, including compound module substitution.
fixture "$TMP/path with spaces/phoenix_app" phoenix
"$INSTALL" --agents both "$TMP/path with spaces/phoenix_app" > "$TMP/log"
contains "$TMP/path with spaces/phoenix_app/AGENTS.md" AcmeShopWeb
# Reject malformed dependency configuration before writing either provider.
fixture "$TMP/bad_deps" phoenix
reject env APP_EXTRA_DEPS=malformed "$INSTALL" --agents both "$TMP/bad_deps"
[ ! -e "$TMP/bad_deps/CLAUDE.md" ] || fail 'partial installation after invalid dependencies'
# Symlink file, symlink parent, symlink app, and invalid destination: no partial installation.
for kind in file parent app collision; do
  dir="$TMP/symlink_$kind"; fixture "$dir" phoenix
  case "$kind" in
    file) ln -s "$TMP/original/mix.exs" "$dir/AGENTS.md" ;;
    parent) ln -s "$TMP/original" "$dir/.agents" ;;
    app) ln -s "$dir" "$TMP/app_link"; dir="$TMP/app_link" ;;
    collision) echo collision > "$dir/.agents" ;;
  esac
  reject "$INSTALL" --agents both --force "$dir"
  [ ! -e "$dir/CLAUDE.md" ] || fail 'partial installation on invalid destination'
done
fixture "$TMP/ambiguous" phoenix
fixture "$TMP/ambiguous" zola
reject "$INSTALL" --agents codex "$TMP/ambiguous"
"$INSTALL" --framework phoenix --agents codex "$TMP/ambiguous" > "$TMP/log"
reject "$INSTALL" --framework sinatra --agents codex "$TMP/ambiguous"
reject env APP_AGENTS=invalid "$INSTALL" "$TMP/original"
reject "$INSTALL" --agents invalid "$TMP/original"
reject "$INSTALL" --framework invalid "$TMP/original"
reject "$INSTALL" --agents
reject "$INSTALL" --unknown "$TMP/original"
reject "$INSTALL" "$TMP/original" "$TMP/original"
fixture "$TMP/precedence" zola
APP_AGENTS=claude "$INSTALL" --agents codex "$TMP/precedence" > "$TMP/log"
[ ! -e "$TMP/precedence/CLAUDE.md" ] || fail 'flag precedence'
fixture "$TMP/default" zola
"$INSTALL" "$TMP/default" </dev/null > "$TMP/log"
[ -f "$TMP/default/CLAUDE.md" ] || fail 'noninteractive default'
fixture "$TMP/environment" zola
APP_AGENTS=both "$INSTALL" "$TMP/environment" > "$TMP/log"
[ -f "$TMP/environment/CLAUDE.md" ] && [ -f "$TMP/environment/AGENTS.md" ] || fail 'environment selection ignored'
# Legacy Phoenix command still adds dependencies once, for either provider.
fixture "$TMP/legacy" phoenix
APP_AGENTS=codex "$ROOT/scripts/inject-skill-docs.sh" "$TMP/legacy" > "$TMP/log"
contains "$TMP/legacy/mix.exs" '{:req,'
contains "$TMP/legacy/mix.exs" '{:oban,'
contains "$TMP/legacy/mix.exs" '{:cucumberex,'
cp "$TMP/legacy/mix.exs" "$TMP/legacy_before"
APP_AGENTS=codex "$ROOT/scripts/inject-skill-docs.sh" --force "$TMP/legacy" > "$TMP/log"
cmp "$TMP/legacy_before" "$TMP/legacy/mix.exs" || fail 'legacy deps not idempotent'
# Fresh scaffold output and retrofit integration.
for framework in sinatra zola; do
  case "$framework" in sinatra) script=new-sinatra-app.sh;; zola) script=new-zola-site.sh;; esac
  for agents in claude codex both; do
    dir="$TMP/fresh_${framework}_${agents}"
    "$ROOT/scripts/$script" --agents "$agents" "$dir" > "$TMP/log"
    if [ "$agents" = codex ] && grep -R -E 'CLAUDE|Claude|\.claude' "$dir"; then fail 'Claude reference in Codex scaffold'; fi
    "$ROOT/scripts/$script" --agents "$agents" --force "$dir" > "$TMP/log"
  done
done
printf 'PASS: installer and scaffold fixtures\n'
