# scripts/app-types.sh — the app-type registry.
#
# Sourced by bootstrap.sh and teardown.sh AFTER their .env, next to
# scripts/provider.sh — same reasoning as GIT_PROVIDER/FRAMEWORK: this file
# APPLIES defaults and coercions, so it must not resolve before a .env value
# could win.
#
# TWO AXES, TWO TABLES.
#
#   APP TYPE  — the SHAPE of the thing being built, and therefore what
#               infrastructure it needs. A 'service' is a long-running web app:
#               droplet, DNS, TLS, maybe a database. A 'cli' or a 'library'
#               needs NONE of that — there is nothing to serve, so there is
#               nothing to provision, no credentials to hold and nothing to tear
#               down. Every step bootstrap.sh skips for a droplet-free app is
#               gated on this table, never on a type name.
#
#   FRAMEWORK — the STACK inside that shape: which scaffold generates the app,
#               which file proves one already exists, which CI workflows it
#               gets. Each framework belongs to exactly one type.
#
# The split is what makes this extensible. Adding gems, hex packages and OTP
# apps is a FRAMEWORK row each under the existing droplet-free 'library' type,
# plus a scaffold script and a CI workflow template per provider. No branch in
# bootstrap.sh changes, because no branch in bootstrap.sh asks "is this a gem?"
# — it asks the table "does this need a droplet?", "what file proves the app is
# already there?", "which workflows does it get?".
#
# Requires from the sourcing script: fail(), log(), warn() already defined.

# ---- the app-type table ---------------------------------------------------------
#
#   1 type        the APP_TYPE value
#   2 flag        the bootstrap.sh flag that selects it
#   3 frameworks  space-separated; the FIRST is the type's default
#   4 droplet     yes = provisions droplet + DNS + TLS + state bucket + registry
#   5 database    yes = a framework of this type MAY want one. no = never, so no
#                 backend is resolved, no cluster provisioned, none torn down
#   6 workflow    the workflow basename IN THE APP REPO that carries this type's
#                 pipeline — what the bootstrap polls, dispatches and diagnoses
#   7 summary     one line, shown by --help and in the run banner
#
APP_TYPE_TABLE='service|--service|phoenix sinatra zola|yes|yes|deploy.yml|a web app on its own droplet, served over HTTPS
cli|--cli|escript|no|no|ci.yml|a command-line program — built, tested and packaged by CI
library|--library|mix|no|no|ci.yml|a reusable package — built and tested by CI'

# ---- the framework table --------------------------------------------------------
#
#   1 framework  the FRAMEWORK value
#   2 type       the app type it belongs to (must exist in the table above)
#   3 signature  the file whose presence means "an app already lives here" — also
#                what ensure_app refuses to generate over
#   4 scaffold   scripts/<this> generates the app, invoked as
#                `scripts/<script> [args...] <app_dir>`. '-' means bootstrap.sh
#                generates it inline (Phoenix: mix phx.new, which insists on
#                creating the directory itself and needs the database flag)
#   5 workflows  space-separated src:dest pairs. src is relative to the
#                provider's template dir (app/.github/workflows or
#                app/.gitea/workflows); dest is the basename written into the
#                app repo. The PR-staging workflow is deliberately absent: it is
#                conditional (wants_staging), not per-framework.
#   6 summary    one line, shown by --help
#
# TO ADD A GEM / HEX PACKAGE / OTP APP: add a row here under type 'library',
# write its scaffold script, and add its ci.<framework>.yml under both
# app/.github/workflows/ and app/.gitea/workflows/. That is the whole change.
# The three commented rows are the worked example:
#
#   gem|library|Gemfile|new-gem.sh|ci.gem.yml:ci.yml|Ruby gem (bundle gem layout)
#   hex|library|mix.exs|new-mix-app.sh --hex|ci.hex.yml:ci.yml|Elixir library published to Hex
#   otp|library|mix.exs|new-mix-app.sh --sup|ci.otp.yml:ci.yml|OTP application (supervision tree)
#
APP_FRAMEWORK_TABLE='phoenix|service|mix.exs|-|deploy.yml:deploy.yml rollback.yml:rollback.yml|Phoenix web app (Elixir)
sinatra|service|Gemfile|new-sinatra-app.sh|deploy.ruby.yml:deploy.yml rollback.ruby.yml:rollback.yml|Sinatra web app (Ruby, SQLite only)
zola|service|config.toml|new-zola-site.sh|deploy.zola.yml:deploy.yml rollback.zola.yml:rollback.yml|Zola static site (no database, no image)
escript|cli|mix.exs|new-mix-app.sh --escript|ci.escript.yml:ci.yml|Elixir escript (one self-contained executable)
mix|library|mix.exs|new-mix-app.sh --lib|ci.mix.yml:ci.yml|Elixir library (a plain mix project)'

# ---- lookups --------------------------------------------------------------------
# Field 1 is the key in both tables; a miss prints nothing, which every caller
# below treats as "unknown".
app_type_row()      { printf '%s\n' "$APP_TYPE_TABLE"      | awk -F'|' -v k="$1" '$1 == k { print; exit }'; }
app_framework_row() { printf '%s\n' "$APP_FRAMEWORK_TABLE" | awk -F'|' -v k="$1" '$1 == k { print; exit }'; }

type_flag()       { app_type_row "$1" | cut -d'|' -f2; }
type_frameworks() { app_type_row "$1" | cut -d'|' -f3; }
type_droplet()    { app_type_row "$1" | cut -d'|' -f4; }
type_database()   { app_type_row "$1" | cut -d'|' -f5; }
type_workflow()   { app_type_row "$1" | cut -d'|' -f6; }
type_summary()    { app_type_row "$1" | cut -d'|' -f7; }

framework_type()      { app_framework_row "$1" | cut -d'|' -f2; }
framework_signature() { app_framework_row "$1" | cut -d'|' -f3; }
framework_scaffold()  { app_framework_row "$1" | cut -d'|' -f4; }
framework_workflows() { app_framework_row "$1" | cut -d'|' -f5; }
framework_summary()   { app_framework_row "$1" | cut -d'|' -f6; }

# ---- capability predicates ------------------------------------------------------
#
# Every droplet-free branch in bootstrap.sh reads THESE, never a type name — so
# a gem added later walks the same paths a CLI already walks, with no edit to
# the branch. They read $APP_TYPE at call time, so resolve_app_type must have
# run first (main does that before anything else).
needs_droplet() { [ "$(type_droplet "$APP_TYPE")" = yes ]; }
has_database()  { [ "$(type_database "$APP_TYPE")" = yes ]; }
is_service()    { [ "$APP_TYPE" = service ]; }
is_cli()        { [ "$APP_TYPE" = cli ]; }
is_library()    { [ "$APP_TYPE" = library ]; }

# ---- help ------------------------------------------------------------------------
# Rendered from the tables, so a row added later documents itself.
app_type_help() {
  local t flag fws droplet db wf summary
  printf '%s\n' "$APP_TYPE_TABLE" | while IFS='|' read -r t flag fws droplet db wf summary; do
    printf '  %-9s %-11s %s\n' "$t" "$flag" "$summary"
    printf '  %-9s %-11s frameworks: %s (droplet: %s)\n' '' '' "$fws" "$droplet"
  done
}

app_framework_help() {
  local f t sig scaffold wfs summary
  printf '%s\n' "$APP_FRAMEWORK_TABLE" | while IFS='|' read -r f t sig scaffold wfs summary; do
    printf '  %-9s %-9s %s\n' "$f" "($t)" "$summary"
  done
}

# The flags that select a droplet-free type, for error messages — derived from
# the table, so a row added later appears here without an edit.
droplet_free_flags() {
  printf '%s\n' "$APP_TYPE_TABLE" \
    | awk -F'|' '$4 == "no" { printf "%s%s", (n++ ? ", " : ""), $2 } END { print "" }'
}

# ---- resolution -----------------------------------------------------------------
#
# Selection has three inputs, in precedence order:
#
#   1. an explicit type — a flag (--cli, --library, --service) or APP_TYPE in
#      the environment
#   2. an explicit FRAMEWORK, which names exactly one type — so `FRAMEWORK=escript`
#      alone still means "build a CLI", and the single-axis mental model that
#      predates this file keeps working unchanged
#   3. the default, 'service' — what every app built before this file was
#
# --no-droplet is a CONSTRAINT, not a fourth input: it asserts "whatever this
# is, it provisions no droplet". Alone it selects the default droplet-free type;
# with --cli (already droplet-free) it is satisfied and redundant; with a type
# that needs one it fails loudly rather than half-applying.
APP_TYPE_DEFAULT=service
NO_DROPLET_DEFAULT_TYPE=library

# Set by bootstrap.sh's argument parsing, before resolve_app_type runs.
APP_TYPE_FLAG=""       # the type a flag selected; empty when none did
REQUIRE_NO_DROPLET=0   # 1 when --no-droplet was passed

resolve_app_type() {
  local requested src

  if [ -n "${APP_TYPE_FLAG:-}" ]; then
    requested="$APP_TYPE_FLAG"; src="$(type_flag "$APP_TYPE_FLAG")"
    [ -n "$src" ] || src="flag"
  elif [ -n "${APP_TYPE:-}" ]; then
    requested="$APP_TYPE"; src="APP_TYPE=$APP_TYPE"
  elif [ -n "${FRAMEWORK:-}" ]; then
    # Infer the type from the framework. An unknown FRAMEWORK is reported
    # against the FULL framework list, not one type's subset: no type has been
    # chosen yet, so no subset would be the right answer.
    requested="$(framework_type "$FRAMEWORK")"
    [ -n "$requested" ] || fail "unknown FRAMEWORK '$FRAMEWORK'. Known frameworks:
$(app_framework_help)"
    src="FRAMEWORK=$FRAMEWORK"
  elif [ "$REQUIRE_NO_DROPLET" = 1 ]; then
    requested="$NO_DROPLET_DEFAULT_TYPE"; src="--no-droplet"
  else
    requested="$APP_TYPE_DEFAULT"; src="default"
  fi

  [ -n "$(app_type_row "$requested")" ] \
    || fail "unknown app type '$requested' (from $src). Known types:
$(app_type_help)"
  APP_TYPE="$requested"

  # --no-droplet against a type that needs one. Refuse rather than coerce: the
  # two readings of that request ("make it a library instead" vs "deploy my
  # Phoenix app without a server") differ in what gets BUILT, and picking one
  # silently would hand back an app nobody asked for.
  if [ "$REQUIRE_NO_DROPLET" = 1 ] && needs_droplet; then
    fail "--no-droplet conflicts with app type '$APP_TYPE' ($(type_summary "$APP_TYPE")).
       A '$APP_TYPE' is served from a droplet — there is no droplet-free variant of it.
       Drop the type flag (--no-droplet on its own builds a $NO_DROPLET_DEFAULT_TYPE), or name a
       droplet-free type: $(droplet_free_flags)"
  fi

  # FRAMEWORK: default to the type's first, else it must belong to the type.
  # A framework from ANOTHER type gets its own message — "not valid for cli" is
  # unhelpful when the real answer is "that one builds a service".
  local valid; valid="$(type_frameworks "$APP_TYPE")"
  if [ -z "${FRAMEWORK:-}" ]; then
    FRAMEWORK="${valid%% *}"
  else
    case " $valid " in
      *" $FRAMEWORK "*) ;;
      *)
        local owner; owner="$(framework_type "$FRAMEWORK")"
        [ -z "$owner" ] \
          && fail "unknown FRAMEWORK '$FRAMEWORK' (valid for app type '$APP_TYPE': $valid)"
        fail "FRAMEWORK '$FRAMEWORK' builds a '$owner', not a '$APP_TYPE' (valid for $APP_TYPE: $valid)" ;;
    esac
  fi

  # The app's pipeline, by name, in its own repo. provider.sh polls, dispatches
  # and diagnoses THIS — so a droplet-free app's CI is watched by exactly the
  # machinery that watches a service's deploy.
  CI_WORKFLOW="$(type_workflow "$APP_TYPE")"
}
