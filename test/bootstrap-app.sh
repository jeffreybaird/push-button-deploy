#!/usr/bin/env bash
# Offline artifact checks for every supported app preparation path and provider.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log() { :; }
warn() { :; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
. "$SCRIPT_DIR/scripts/app-types.sh"
. "$SCRIPT_DIR/scripts/provider.sh"
. "$SCRIPT_DIR/scripts/bootstrap/app.sh"
is_phoenix() { [ "$FRAMEWORK" = phoenix ]; }
is_sinatra() { [ "$FRAMEWORK" = sinatra ]; }
is_static() { [ "$FRAMEWORK" = zola ]; }
wants_staging() { needs_droplet && ! is_static && is_github; }
# Local build/toolchain discovery is outside file-installation tests.
pin_toolchain() { [ -d "$APP_DIR/rel" ]; }
mix() { if [ "$1" = phx.gen.release ]; then mkdir -p rel; fi; }

for provider in github gitea; do
  for spec in 'service phoenix sqlite' 'service phoenix postgres' \
              'service sinatra sqlite' 'service zola none' \
              'cli escript none' 'cli ruby-cli none' 'cli bash-cli none' \
              'cli ts-cli none' 'library mix none'; do
    read -r app_type framework backend <<< "$spec"
    app_dir="$WORK/$provider-$framework-$backend"
    mkdir -p "$app_dir/config"
    cat > "$app_dir/mix.exs" <<'EOF'
defmodule Example.MixProject do
  def project, do: [app: :example]
end
EOF
    printf 'import Config\nconfig :example, Example.Repo, url: "unused"\n' > "$app_dir/config/runtime.exs"
    printf '3.4.1\n' > "$app_dir/.ruby-version"
    # Explicit inputs must not leak their temporary context into callers.
    APP_DIR=caller-directory; FRAMEWORK=caller-framework
    prepare_app "$app_dir" "$app_type" "$framework" "$backend" "$provider"
    [ "$APP_DIR" = caller-directory ] && [ "$FRAMEWORK" = caller-framework ]
    [ "$(cat "$app_dir/.app-type")" = "$app_type" ]
    for pair in $(framework_workflows "$app_type" "$framework"); do
      cmp "$SCRIPT_DIR/app/.$provider/workflows/${pair%%:*}" "$app_dir/.$provider/workflows/${pair##*:}"
    done
    if [ "$app_type" != service ]; then
      [ ! -e "$app_dir/Dockerfile" ] && [ ! -d "$app_dir/deploy" ]
    elif [ "$framework" = zola ]; then
      [ -f "$app_dir/deploy/ci/remote.sh" ]
      [ ! -e "$app_dir/Dockerfile" ] && [ ! -e "$app_dir/deploy/compose.yaml" ]
      cmp "$SCRIPT_DIR/deploy/site.static.caddy.tmpl" "$app_dir/deploy/site.caddy.tmpl"
      [ -f "$app_dir/deploy/publish.sh" ] && [ ! -e "$app_dir/deploy/swap.sh" ]
    else
      [ -f "$app_dir/Dockerfile" ] && [ -f "$app_dir/deploy/swap.sh" ]
      [ -f "$app_dir/deploy/ci/runtime-env.sh" ]
      if [ "$framework" = sinatra ]; then expected=compose.sinatra.yaml
      elif [ "$backend" = sqlite ]; then expected=compose.sqlite.yaml
      else expected=compose.yaml; fi
      cmp "$SCRIPT_DIR/deploy/$expected" "$app_dir/deploy/compose.yaml"
      if [ "$provider" = github ]; then
        [ -f "$app_dir/.github/workflows/staging.yml" ]
        if [ "$backend" = sqlite ]; then [ -f "$app_dir/deploy/compose.staging.yaml" ]; fi
      else
        [ ! -e "$app_dir/.gitea/workflows/staging.yml" ]
        [ ! -e "$app_dir/deploy/compose.staging.yaml" ]
      fi
      if [ "$framework" = phoenix ]; then
        bash "$SCRIPT_DIR/scripts/ensure-release-task.sh" --check "$app_dir" >/dev/null
      fi
    fi
  done
done

mkdir -p "$WORK/shop_api" "$WORK/my-tool/bin"
touch "$WORK/shop_api/Gemfile" "$WORK/my-tool/bin/my-tool"
[ "$(read_app_identity "$WORK/shop_api" service sinatra ruby)" = 'shop_api|ShopApi' ]
[ "$(read_app_identity "$WORK/my-tool" cli bash-cli bash)" = 'my-tool|(no module: bash)' ]
unset PROJECT_NAME REGION DNS_RECORD
derive_infrastructure_names shop_api
[ "$PROJECT_NAME" = shop-api ] && [ "$APP_SLUG" = shop-api ]
[ "$DNS_RECORD" = shop-api ] && [ "$REGION" = nyc3 ]
echo 'bootstrap app checks passed (18 stack/provider combinations)'
