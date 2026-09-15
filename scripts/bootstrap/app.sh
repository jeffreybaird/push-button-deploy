# Application generation, identity, and deployment-file preparation.
# Requires SCRIPT_DIR, logging helpers, app-types.sh, and capability predicates.
# read_app_identity emits name|module; prepare_app accepts a scoped app context.
# Legacy copy/toolchain helpers consume that context without changing the caller.

# Generate the app when the target directory is empty or missing — this is the
# "empty directory -> deployed app" entry point. An existing app (detected by its
# framework signature file) is used as-is; a non-empty non-app directory is
# refused rather than generated over.
ensure_app() {
  local sig scaffold
  # Both questions — "is an app already here?" and "what generates one?" — are
  # answered by the stack's registry row, so a stack added later needs no branch
  # here. The row is keyed on the (type, framework) pair: a Ruby CLI and a Ruby
  # web app are different rows, and only the pair tells them apart.
  sig="$(framework_signature "$APP_TYPE" "$FRAMEWORK")"
  [ -n "$sig" ] || fail "no signature file registered for $APP_TYPE/$FRAMEWORK (scripts/app-types.sh)"
  # `<name>` in a signature is the app directory's basename — for stacks whose
  # entry point is named after the app (bash: bin/<name>).
  case "$sig" in *'<name>'*) sig="${sig%%<name>*}$(basename "$APP_DIR")${sig#*<name>}" ;; esac
  if [ -f "$APP_DIR/$sig" ]; then
    log "app: using existing $APP_DIR"
    return 0
  fi
  if [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR")" ]; then
    fail "$APP_DIR is not empty and has no $sig — refusing to generate over it"
  fi

  # The row holds the scaffold as `script [args...]`; the app directory is
  # always the last argument. Sinatra and Zola scaffold themselves in pure bash
  # (their builds happen in CI), and so do the droplet-free Elixir types.
  scaffold="$(framework_scaffold "$APP_TYPE" "$FRAMEWORK")"
  if [ "$scaffold" != "-" ]; then
    # Deliberate word splitting: the row's args are shell words, not one string.
    # shellcheck disable=SC2086
    set -- $scaffold
    local generator="$1"; shift
    [ -x "$SCRIPT_DIR/scripts/$generator" ] \
      || fail "scripts/$generator is missing or not executable (scripts/app-types.sh names it for $APP_TYPE/$FRAMEWORK)"
    "$SCRIPT_DIR/scripts/$generator" "$@" "$APP_DIR"
    return 0
  fi

  # Phoenix: phx.new insists on creating the directory itself (prompts otherwise).
  [ -d "$APP_DIR" ] && rmdir "$APP_DIR"
  local name parent
  name="$(basename "$APP_DIR")"
  parent="$(dirname "$APP_DIR")"
  # On the SQLite backend, generate an Ecto.Adapters.SQLite3 app (DATABASE_PATH
  # config, no Postgrex) instead of the phx.new Postgres default.
  local db_flag=""
  is_sqlite && db_flag="--database sqlite3"
  log "generating Phoenix app '$name' (mix phx.new --no-install ${db_flag:-postgres})"
  ( cd "$parent" && mix phx.new "$name" --no-install $db_flag )
  # Freshly generated apps get the Claude skill docs (app-template/) and the
  # deps the docs assume. Existing apps are left alone — run the script by
  # hand to retrofit: ./scripts/inject-skill-docs.sh <app_dir>
  "$SCRIPT_DIR/scripts/inject-skill-docs.sh" "$APP_DIR"
}

read_app_identity() { # $1 directory, $2 type, $3 framework, $4 language
  local APP_DIR="$1" APP_TYPE="$2" FRAMEWORK="$3" LANGUAGE="$4" APP_NAME APP_MODULE
  local sig
  sig="$(framework_signature "$APP_TYPE" "$FRAMEWORK")"
  case "$sig" in *'<name>'*) sig="${sig%%<name>*}$(basename "$APP_DIR")${sig#*<name>}" ;; esac
  [ -f "$APP_DIR/$sig" ] || fail "no $sig in $APP_DIR — generation failed?"

  case "$LANGUAGE" in
    elixir)
      # shellcheck source=scripts/app-meta.sh
      . "$SCRIPT_DIR/scripts/app-meta.sh"
      APP_NAME="$(app_name "$APP_DIR")"
      APP_MODULE="$(app_module "$APP_DIR")" ;;
    ruby)
      APP_NAME="$(basename "$APP_DIR")"
      case "$APP_NAME" in
        [a-z]*[!a-z0-9_]*|*[!a-z0-9_]*|[!a-z]*)
          fail "Ruby app name '$APP_NAME' must be lower_snake_case (the dir basename names the app, its module and its infra)" ;;
      esac
      APP_MODULE="$(printf '%s' "$APP_NAME" | awk -F_ '{o=""; for(i=1;i<=NF;i++){o=o toupper(substr($i,1,1)) substr($i,2)} print o}')" ;;
    *)
      APP_NAME="$(basename "$APP_DIR")"
      case "$APP_NAME" in
        # Hyphens are allowed here where they are not above: nothing derives an
        # Elixir atom or a Ruby module from these names, and a hyphen is the
        # natural spelling for both a domain label and a command.
        [a-z]*[!a-z0-9_-]*|*[!a-z0-9_-]*|[!a-z]*)
          fail "name '$APP_NAME' must be lowercase letters, digits, '_' or '-' (start with a letter): the dir basename names it" ;;
      esac
      # Nothing evaluates a module for these; carried only so the log line and
      # downstream references have a value.
      APP_MODULE="(no module: $LANGUAGE)" ;;
  esac
  printf '%s|%s\n' "$APP_NAME" "$APP_MODULE"
}

# Sets PROJECT_NAME, REGION, DNS_RECORD and APP_SLUG from the app name and
# optional caller overrides. Does not inspect or modify application files.
derive_infrastructure_names() { # $1 app name
  local APP_NAME="$1"
  # App names are snake_case, but DO buckets/DBs and DNS labels only allow
  # hyphens — translate when deriving infra names from the app name.
  local infra_name; infra_name="$(printf '%s' "$APP_NAME" | tr '_' '-')"
  PROJECT_NAME="${PROJECT_NAME:-$infra_name}"
  case "$PROJECT_NAME" in
    *[!a-z0-9-]*|-*|*-) fail "PROJECT_NAME '$PROJECT_NAME' is invalid: lowercase letters, digits, and inner hyphens only (it names DO buckets/DBs/DNS)" ;;
  esac
  REGION="${REGION:-nyc3}"
  DNS_RECORD="${DNS_RECORD:-$infra_name}"
  # The app's identity ON THE DROPLET. One droplet can host several apps, so
  # everything that could collide with a neighbour is keyed on this: the stack
  # directory (/root/apps/<slug>), the compose project (hence container and
  # volume names), the shared Caddy's site file, and the per-color network
  # aliases Caddy dials. PROJECT_NAME is already unique per app and already
  # hyphenated, which is what compose project names and DNS labels accept.
  APP_SLUG="$PROJECT_NAME"
}

log_app_identity() {
  if needs_droplet; then
    log "app: $APP_NAME ($APP_MODULE) [$APP_TYPE/$FRAMEWORK, $LANGUAGE] | project: $PROJECT_NAME | region: $REGION"
  else
    # PROJECT_NAME/REGION/DNS_RECORD are still resolved above so nothing
    # downstream has to special-case an unset variable, but none of them names
    # anything on this path: no bucket, no cluster, no DNS record exists to name.
    log "app: $APP_NAME ($APP_MODULE) [$APP_TYPE/$FRAMEWORK, $LANGUAGE] — repo + CI only, no infrastructure"
  fi
}

# Pin the app's Dockerfile ARGs (CI reads the same ARGs) to the local Elixir/OTP
# that generated the app: phx_new can emit syntax older Elixirs cannot compile
# (e.g. the ~r"..."E regex modifier), so the pipeline toolchain must not lag the
# local one. Overridable via ELIXIR_VERSION / OTP_VERSION env.
pin_toolchain() {
  local df="$APP_DIR/Dockerfile" ex otp debian tag
  ex="${ELIXIR_VERSION:-$(elixir --version 2>/dev/null | sed -nE 's/^Elixir ([0-9.]+).*/\1/p')}"
  otp="${OTP_VERSION:-$(erl -noshell -eval \
    '{ok,V}=file:read_file(filename:join([code:root_dir(),"releases",erlang:system_info(otp_release),"OTP_VERSION"])),io:fwrite(V),halt().' \
    2>/dev/null | tr -d '[:space:]')}"
  [ -n "$ex" ] && [ -n "$otp" ] || fail "could not detect local Elixir/OTP versions (set ELIXIR_VERSION/OTP_VERSION env)"

  # The Dockerfile's DEBIAN_VERSION pins a snapshot like bookworm-YYYYMMDD-slim;
  # only the flavor is authoritative — hexpm republishes on new snapshot dates
  # and drops the old tags, so the date must float to what's published.
  local flavor
  flavor="$(sed -nE 's/^ARG DEBIAN_VERSION=([a-z]+)-.*$/\1/p' "$df" | head -1)"
  [ -n "$flavor" ] || fail "no ARG DEBIAN_VERSION in $df"

  # The combo must exist as a published hexpm builder image or the release
  # build dies mid-pipeline. The repo has thousands of tags, so targeted
  # queries only: first ask for the exact local OTP; if unpublished (hexpm lags
  # new OTP releases), scan the first pages of a descending-by-name listing —
  # that's where the newest OTP versions sit — and take the newest published
  # stable OTP. What matters for compiling the generated app is the Elixir
  # version; OTP only needs to be compatible. Either way pin the newest
  # snapshot date published for the chosen OTP.
  local hub="https://hub.docker.com/v2/repositories/hexpm/elixir/tags" pairs chosen date
  hub_pairs() {
    grep -Eo '"name":"[^"]*"' \
      | sed -nE "s/^\"name\":\"${ex}-erlang-([0-9.]+)-debian-${flavor}-([0-9]+)-slim\"$/\1 \2/p"
  }
  # `|| true`: an empty result exits the grep inside hub_pairs nonzero, which
  # under set -e -o pipefail would kill the script SILENTLY mid-assignment.
  pairs="$(curl -fsSL "${hub}/?page_size=100&name=${ex}-erlang-${otp}-debian-${flavor}-" 2>/dev/null | hub_pairs || true)"
  if [ -n "$pairs" ]; then
    chosen="$otp"
  else
    local page
    pairs="$(for page in 1 2 3 4 5; do
      curl -fsSL "${hub}/?page_size=100&ordering=name&page=${page}&name=${ex}-erlang-" 2>/dev/null
    done | hub_pairs || true)"
    [ -n "$pairs" ] \
      || fail "no hexpm/elixir image published for Elixir $ex (debian ${flavor}-*-slim) — pick a combo from hub.docker.com/r/hexpm/elixir/tags and set ELIXIR_VERSION/OTP_VERSION"
    chosen="$(printf '%s\n' "$pairs" | awk '{print $1}' | sort -u -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)"
    log "toolchain: local OTP $otp has no hexpm image; pinning newest published OTP $chosen"
  fi
  date="$(printf '%s\n' "$pairs" | awk -v o="$chosen" '$1==o {print $2}' | sort -n | tail -1)"

  log "toolchain pins: elixir $ex / otp $chosen / debian ${flavor}-${date}-slim"
  sed -E \
    -e "s/^ARG ELIXIR_VERSION=.*/ARG ELIXIR_VERSION=${ex}/" \
    -e "s/^ARG OTP_VERSION=.*/ARG OTP_VERSION=${chosen}/" \
    -e "s/^ARG DEBIAN_VERSION=.*/ARG DEBIAN_VERSION=${flavor}-${date}-slim/" \
    "$df" > "$df.tmp" && mv "$df.tmp" "$df"
}

# Pin the Sinatra app's Dockerfile RUBY_VERSION ARG to .ruby-version (single
# source of truth; CI reads the same file). Overridable via RUBY_VERSION env.
pin_ruby() {
  local df="$APP_DIR/Dockerfile" rv
  rv="${RUBY_VERSION:-$(tr -d '[:space:]' < "$APP_DIR/.ruby-version" 2>/dev/null)}"
  [ -n "$rv" ] || { warn "no .ruby-version and no RUBY_VERSION — leaving Dockerfile default"; return 0; }
  sed -E "s/^ARG RUBY_VERSION=.*/ARG RUBY_VERSION=${rv}/" "$df" > "$df.tmp" && mv "$df.tmp" "$df"
  log "toolchain: pinned Dockerfile RUBY_VERSION=$rv"
}

# The deploy-time files that are the SAME for every app: this app's blue/green
# stack (swap.sh) plus the droplet's SHARED edge proxy (Caddyfile, its compose
# file, the per-app site template and the script that installs all three). The
# edge files travel in every app repo on purpose — any app's deploy must be able
# to stand the proxy up, including the first one on a fresh droplet.
copy_deploy_files() {
  mkdir -p "$APP_DIR/deploy/ci"
  cp "$SCRIPT_DIR"/deploy/ci/*.sh "$APP_DIR/deploy/ci/"
  # Shared by every framework: the droplet's edge proxy.
  cp "$SCRIPT_DIR/deploy/Caddyfile" \
     "$SCRIPT_DIR/deploy/edge-compose.yaml" \
     "$SCRIPT_DIR/deploy/edge.sh" \
     "$APP_DIR/deploy/"

  # The site file and the publish mechanism differ by what is being served.
  # edge.sh always reads deploy/site.caddy.tmpl, so the right template is copied
  # UNDER THAT NAME rather than teaching edge.sh about frameworks.
  if is_static; then
    # Caddy serves files off disk; publishing is a symlink flip, not a swap.
    cp "$SCRIPT_DIR/deploy/site.static.caddy.tmpl" "$APP_DIR/deploy/site.caddy.tmpl"
    cp "$SCRIPT_DIR/deploy/publish.sh"             "$APP_DIR/deploy/publish.sh"
    rm -f "$APP_DIR/deploy/swap.sh"
  else
    # Caddy reverse-proxies to the live color; publishing is the blue/green swap.
    cp "$SCRIPT_DIR/deploy/site.caddy.tmpl" "$APP_DIR/deploy/site.caddy.tmpl"
    cp "$SCRIPT_DIR/deploy/swap.sh"         "$APP_DIR/deploy/swap.sh"
    # Tears a PR staging environment off the droplet. Travels with every dynamic
    # app for the same reason edge.sh does: the workflow that needs it ships it.
    cp "$SCRIPT_DIR/deploy/staging-down.sh" "$APP_DIR/deploy/staging-down.sh"
  fi
}

# The staging environment's two SQLITE-ONLY files. They are what keep a pull
# request away from production's backups: replication goes to a path inside the
# environment's own volume, and the archive-to-Spaces loop is switched off. The
# Postgres stack needs neither — it has no such services, and its staging
# isolation is a separate database in the same cluster.
# Copy the staging workflow, but only from a template set that HAS one. Keeps
# pipeline installation identical across providers instead of making each caller
# re-derive which provider ships what.
copy_staging_workflow() { # $1 template basename, $2 template dir, $3 dest dir
  local tpl="$SCRIPT_DIR/$2/$1"
  wants_staging || return 0
  [ -f "$tpl" ] || return 0
  cp "$tpl" "$APP_DIR/$3/staging.yml"
}

copy_staging_files() {
  wants_staging || return 0
  cp "$SCRIPT_DIR/deploy/compose.staging.yaml"   "$APP_DIR/deploy/compose.staging.yaml"
  cp "$SCRIPT_DIR/deploy/litestream.staging.yml" "$APP_DIR/deploy/litestream.staging.yml"
}

# Copy the framework's workflows out of the provider's template set. The
# registry names them as `src:dest` pairs — src is the template's basename (they
# are suffixed per framework: deploy.ruby.yml, ci.escript.yml), dest is what the
# app repo calls it (deploy.yml, ci.yml). Keeping the mapping in the table is
# what lets a new framework ship a pipeline without an edit here.
copy_workflows() { # $1 template dir (repo-relative), $2 dest dir (app-relative)
  local pair src dst
  for pair in $(framework_workflows "$APP_TYPE" "$FRAMEWORK"); do
    src="${pair%%:*}"; dst="${pair##*:}"
    [ -f "$SCRIPT_DIR/$1/$src" ] \
      || fail "no workflow template $1/$src — $APP_TYPE/$FRAMEWORK names it in scripts/app-types.sh, but this provider does not ship one"
    cp "$SCRIPT_DIR/$1/$src" "$APP_DIR/$2/$dst"
  done
}

# Prepare only Phoenix's application source; deployment templates are separate.
prepare_phoenix_release() { # $1 app directory, $2 database backend
  local app_dir="$1" backend="$2"
  ( cd "$app_dir"
    mix deps.get
    [ -d rel ] || mix phx.gen.release
  )
  if [ "$backend" = postgres ]; then
    "$SCRIPT_DIR/scripts/ensure-db-tls.sh" "$app_dir"
  fi
  "$SCRIPT_DIR/scripts/ensure-release-task.sh" "$app_dir"
}

install_docker_runtime() { # $1 app directory, $2 framework
  local APP_DIR="$1" framework="$2"
  case "$framework" in
    sinatra)
      cp "$SCRIPT_DIR/app/Dockerfile.ruby" "$APP_DIR/Dockerfile"
      cp "$SCRIPT_DIR/app/.dockerignore.ruby" "$APP_DIR/.dockerignore"
      pin_ruby ;;
    phoenix)
      cp "$SCRIPT_DIR/app/Dockerfile" "$APP_DIR/Dockerfile"
      cp "$SCRIPT_DIR/app/.dockerignore" "$APP_DIR/.dockerignore"
      pin_toolchain ;;
  esac
}

install_runtime_stack() { # $1 app directory, $2 framework, $3 database backend
  local APP_DIR="$1" framework="$2" backend="$3" template
  if [ "$framework" = sinatra ]; then template=compose.sinatra.yaml
  elif [ "$backend" = sqlite ]; then template=compose.sqlite.yaml
  else template=compose.yaml; fi
  cp "$SCRIPT_DIR/deploy/$template" "$APP_DIR/deploy/compose.yaml"
  if [ "$backend" = sqlite ]; then
    cp "$SCRIPT_DIR/deploy/litestream.yml" "$APP_DIR/deploy/litestream.yml"
    copy_staging_files
  fi
}

# File installation shared by every stack. Application build/patch steps belong
# to prepare_phoenix_release() and install_docker_runtime().
install_pipeline_files() { # $1 app directory, $2 provider
  local APP_DIR="$1" provider="$2" wf_dir tpl_wf_dir staging_template
  wf_dir=".$provider/workflows"
  tpl_wf_dir="app/$wf_dir"
  mkdir -p "$APP_DIR/$wf_dir"
  copy_workflows "$tpl_wf_dir" "$wf_dir"
  if needs_droplet; then
    mkdir -p "$APP_DIR/deploy"
    copy_deploy_files
    if ! is_static; then
      if is_sinatra; then staging_template=staging.ruby.yml
      else staging_template=staging.yml; fi
      copy_staging_workflow "$staging_template" "$tpl_wf_dir" "$wf_dir"
    fi
  fi
}

# The resolved app context is scoped to this operation and its helper calls.
# Inputs: directory, app type, framework, backend, code host. Staging policy is
# supplied by wants_staging(); toolchain overrides remain optional environment.
prepare_app() {
  local APP_DIR="$1" APP_TYPE="$2" FRAMEWORK="$3" DATABASE_BACKEND="$4" GIT_PROVIDER="$5"
  printf '%s\n' "$APP_TYPE" > "$APP_DIR/.app-type"
  if is_phoenix; then
    prepare_phoenix_release "$APP_DIR" "$DATABASE_BACKEND"
  fi
  if needs_droplet && ! is_static; then
    install_docker_runtime "$APP_DIR" "$FRAMEWORK"
  fi
  install_pipeline_files "$APP_DIR" "$GIT_PROVIDER"
  if needs_droplet && ! is_static; then
    install_runtime_stack "$APP_DIR" "$FRAMEWORK" "$DATABASE_BACKEND"
  fi
}
