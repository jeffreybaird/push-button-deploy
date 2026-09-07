#!/usr/bin/env bash
# Install repository-local Claude and/or Codex guides. No app/dependency changes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/agent-files-common.sh"
agent_options "$@"
[ -d "$AGENT_DIR" ] || agent_fail "no app directory: $AGENT_DIR"
# Reject any symlink along a destination, including ancestors of the app directory.
check_path() {
  local path="$1"
  while [ "$path" != / ] && [ "$path" != . ]; do
    [ ! -L "$path" ] || agent_fail "symlink destination refused: $path"
    path="$(dirname "$path")"
  done
}
case "$AGENT_DIR" in /*) ;; *) AGENT_DIR="$PWD/$AGENT_DIR";; esac
check_path "$AGENT_DIR"
AGENT_DIR="$(cd "$AGENT_DIR" && pwd)"
if [ -z "$AGENT_FRAMEWORK" ]; then
  count=0
  for pair in phoenix:mix.exs sinatra:Gemfile zola:config.toml; do
    if [ -f "$AGENT_DIR/${pair#*:}" ]; then
      AGENT_FRAMEWORK="${pair%%:*}"; count=$((count + 1))
    fi
  done
  [ "$count" -eq 1 ] || agent_fail 'cannot detect a unique framework; use --framework phoenix|sinatra|zola'
fi
case "$AGENT_FRAMEWORK" in
  phoenix) template=app-template; signature=mix.exs ;;
  sinatra) template=app-template-ruby; signature=Gemfile ;;
  zola) template=app-template-zola; signature=config.toml ;;
esac
[ -f "$AGENT_DIR/$signature" ] || agent_fail "no $signature in $AGENT_DIR"
TEMPLATE_DIR="$SCRIPT_DIR/../$template"
[ -f "$TEMPLATE_DIR/CLAUDE.md" ] || agent_fail 'missing instruction template'
if [ "$AGENT_FRAMEWORK" = phoenix ]; then
  . "$SCRIPT_DIR/app-meta.sh"
  AGENT_NAME="$(app_name "$AGENT_DIR")"; AGENT_MODULE="$(app_module "$AGENT_DIR")"
else
  AGENT_NAME="$(basename "$AGENT_DIR")"
  case "$AGENT_FRAMEWORK:$AGENT_NAME" in
    sinatra:*) [[ "$AGENT_NAME" =~ ^[a-z][a-z0-9_]*$ ]] || agent_fail 'Sinatra directory name must be lower_snake_case';;
    zola:*) [[ "$AGENT_NAME" =~ ^[a-z][a-z0-9_-]*$ ]] || agent_fail 'invalid Zola directory name';;
  esac
  AGENT_MODULE="$(printf '%s' "$AGENT_NAME" | awk -F_ '{for(i=1;i<=NF;i++) printf "%s%s",toupper(substr($i,1,1)),substr($i,2)}')"
fi
AGENT_TITLE="$(printf '%s' "$AGENT_NAME" | tr '_-' '  ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')"
export AGENT_NAME AGENT_MODULE AGENT_TITLE
agent_select
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
render() {
  local provider="$1" source="$2" dest="$3" topic="${4:-}" description="${5:-}"
  mkdir -p "$stage/$(dirname "$dest")"
  perl "$SCRIPT_DIR/render-agent-file.pl" "$provider" "$source" "$topic" "$description" > "$stage/$dest"
}
if [ "$AGENT_SELECTION" != codex ]; then
  render claude "$TEMPLATE_DIR/CLAUDE.md" CLAUDE.md
  for src in "$TEMPLATE_DIR"/.claude/*.md; do
    render claude "$src" ".claude/$(basename "$src")"
  done
  for name in settings.json cloud-setup.sh; do
    [ ! -f "$TEMPLATE_DIR/.claude/$name" ] || render claude "$TEMPLATE_DIR/.claude/$name" ".claude/$name"
  done
  [ ! -f "$stage/.claude/cloud-setup.sh" ] || chmod +x "$stage/.claude/cloud-setup.sh"
fi
if [ "$AGENT_SELECTION" != claude ]; then
  render codex "$TEMPLATE_DIR/CLAUDE.md" AGENTS.md
  for src in "$TEMPLATE_DIR"/.claude/*.md; do
    topic="$(basename "$src" .md)"
    description="$(awk -F '\t' -v topic="$topic" '$1 == topic {print $2}' "$TEMPLATE_DIR/skill-metadata.tsv")"
    [ -n "$description" ] || agent_fail "missing metadata: $topic"
    render codex "$src" ".agents/skills/$topic/SKILL.md" "$topic" "$description"
  done
  # Every converted guide reference must resolve within the rendered output.
  while IFS= read -r ref; do
    [ -f "$stage/$ref" ] || agent_fail "unresolved guide reference: $ref"
  done < <(find "$stage" -name '*.md' -exec perl -ne 'while (m{(\.agents/skills/[a-z0-9-]+/SKILL\.md)}g) {print "$1\n"}' {} + | sort -u)
fi
# Complete destination validation before writing any file.
while IFS= read -r -d '' src; do
  dest="$AGENT_DIR/${src#"$stage/"}"
  check_path "$dest"
  [ ! -e "$dest" ] || [ -f "$dest" ] || agent_fail "destination is not a regular file: $dest"
  parent="$(dirname "$dest")"
  while [ "$parent" != "$AGENT_DIR" ]; do
    [ ! -e "$parent" ] || [ -d "$parent" ] || agent_fail "destination parent is not a directory: $parent"
    parent="$(dirname "$parent")"
  done
done < <(find "$stage" -type f -print0)
# Validate dependency configuration before installing; reporting never edits mix.exs.
if [ "$AGENT_FRAMEWORK" = phoenix ]; then
  perl "$SCRIPT_DIR/agent-deps.pl" report "$AGENT_DIR/mix.exs"
fi
while IFS= read -r -d '' src; do
  relative="${src#"$stage/"}"; dest="$AGENT_DIR/$relative"
  if [ -f "$dest" ] && cmp -s "$src" "$dest" && { [ ! -x "$src" ] || [ -x "$dest" ]; }; then
    printf 'agent files: identical %s\n' "$relative"
  elif [ -f "$dest" ] && [ "$AGENT_FORCE" -eq 0 ]; then
    printf 'agent files: preserved differing %s (use --force to replace)\n' "$relative"
  else
    mkdir -p "$(dirname "$dest")"
    cp -p "$src" "$dest"
    printf 'agent files: installed %s\n' "$relative"
  fi
done < <(find "$stage" -type f -print0)
