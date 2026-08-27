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
#   3 droplet     yes = provisions droplet + DNS + TLS + state bucket + registry
#   4 database    yes = a stack of this type MAY want one. no = never, so no
#                 backend is resolved, no cluster provisioned, none torn down
#   5 workflow    the workflow basename IN THE APP REPO that carries this type's
#                 pipeline — what the bootstrap polls, dispatches and diagnoses
#   6 summary     one line, shown by --help and in the run banner
#
# The type's stacks are NOT listed here — they are the rows of the second table
# whose type column names this one, and the type's DEFAULT is the first of them.
# One list, not two to keep in step.
#
APP_TYPE_TABLE='service|--service|yes|yes|deploy.yml|a web app on its own droplet, served over HTTPS
cli|--cli|no|no|ci.yml|a command-line program — built, tested and packaged by CI
library|--library|no|no|ci.yml|a reusable package — built and tested by CI'

# ---- the stack table ------------------------------------------------------------
#
# One row per (type, framework). The pair is the key: a Ruby CLI and a Ruby web
# app are different rows of the same language, which is why the framework name
# alone is not the identity.
#
#   1 type       the app type this stack belongs to (a row of the table above)
#   2 framework  the FRAMEWORK value; unique within its type, and kept unique
#                across the table so naming one alone also picks the type
#   3 language   what --lang / --<type>=<lang> matches. THE user-facing axis for
#                the types whose stacks differ only by language: `--cli ruby`
#                and `--cli typescript` are the same CLI in two languages.
#                Several rows may share a language across types (elixir builds a
#                Phoenix service, an escript CLI and a mix library), which is
#                why it is matched WITHIN a type and never used to infer one.
#   4 aliases    space-separated alternate spellings of the LANGUAGE ('ts' for
#                typescript, 'sh' for bash), '-' for none. Matched within a type
#                only, exactly like the language column — never used to infer a
#                type, because a language is shared across types by design.
#   5 signature  the file whose presence means "an app already lives here" —
#                also what ensure_app refuses to generate over. `<name>` in it
#                expands to the app directory's basename, for stacks whose entry
#                point is named after the app (bash: bin/<name>).
#   6 scaffold   scripts/<this> generates the app, invoked as
#                `scripts/<script> [args...] <app_dir>`. '-' means bootstrap.sh
#                generates it inline (Phoenix: mix phx.new, which insists on
#                creating the directory itself and needs the database flag)
#   7 workflows  space-separated src:dest pairs. src is relative to the
#                provider's template dir (app/.github/workflows or
#                app/.gitea/workflows); dest is the basename written into the
#                app repo. The PR-staging workflow is deliberately absent: it is
#                conditional (wants_staging), not per-stack.
#   8 summary    one line, shown by --help
#
# EVERY CLI STACK SHIPS REAL ARGUMENT PARSING — `mytool --bar baz`, --help,
# --version, positional arguments and exit codes — over its language's standard
# option parser (OptionParser, node:util parseArgs, Elixir's OptionParser, a
# hand-rolled long/short/`--k=v` loop for bash). None of them is a script you
# configure by exporting variables in front of it.
#
# TO ADD A GEM / HEX PACKAGE / OTP APP: add a row under type 'library', write
# its scaffold script, and add its ci.<framework>.yml under both
# app/.github/workflows/ and app/.gitea/workflows/. That is the whole change.
# The three commented rows are the worked example:
#
#   library|gem|ruby|-|<name>.gemspec|new-gem.sh|ci.gem.yml:ci.yml|Ruby gem
#   library|hex|elixir|-|mix.exs|new-mix-app.sh --hex|ci.hex.yml:ci.yml|Elixir library published to Hex
#   library|otp|elixir|-|mix.exs|new-mix-app.sh --sup|ci.otp.yml:ci.yml|OTP application (supervision tree)
#
APP_STACK_TABLE='service|phoenix|elixir|-|mix.exs|-|deploy.yml:deploy.yml rollback.yml:rollback.yml|Phoenix web app
service|sinatra|ruby|-|Gemfile|new-sinatra-app.sh|deploy.ruby.yml:deploy.yml rollback.ruby.yml:rollback.yml|Sinatra web app (SQLite only)
service|zola|static|-|config.toml|new-zola-site.sh|deploy.zola.yml:deploy.yml rollback.zola.yml:rollback.yml|Zola static site (no database, no image)
cli|escript|elixir|beam|mix.exs|new-mix-app.sh --escript|ci.escript.yml:ci.yml|one self-contained executable, via mix escript.build
cli|ruby-cli|ruby|rb|Gemfile|new-ruby-cli.sh|ci.ruby-cli.yml:ci.yml|a gem-layout CLI on OptionParser, installable with gem install
cli|bash-cli|bash|sh shell|bin/<name>|new-bash-cli.sh|ci.bash-cli.yml:ci.yml|a dependency-free shell CLI, shellcheck-clean
cli|ts-cli|typescript|ts node js javascript|package.json|new-ts-cli.sh|ci.ts-cli.yml:ci.yml|a Node CLI on node:util parseArgs, installable with npm i -g
library|mix|elixir|-|mix.exs|new-mix-app.sh --lib|ci.mix.yml:ci.yml|Elixir library (a plain mix project)'

# ---- lookups --------------------------------------------------------------------
# The type table is keyed on field 1. The stack table is keyed on the (type,
# framework) PAIR — resolve_app_type is what turns a user's framework/language
# into that pair, and every lookup below takes the resolved pair. A miss prints
# nothing, which every caller treats as "unknown".
app_type_row() { printf '%s\n' "$APP_TYPE_TABLE" | awk -F'|' -v k="$1" '$1 == k { print; exit }'; }

type_flag()     { app_type_row "$1" | cut -d'|' -f2; }
type_droplet()  { app_type_row "$1" | cut -d'|' -f3; }
type_database() { app_type_row "$1" | cut -d'|' -f4; }
type_workflow() { app_type_row "$1" | cut -d'|' -f5; }
type_summary()  { app_type_row "$1" | cut -d'|' -f6; }

# Every stack row of one type, in table order — the first is the type's default.
type_stacks()     { printf '%s\n' "$APP_STACK_TABLE" | awk -F'|' -v t="$1" '$1 == t'; }
type_frameworks() { type_stacks "$1" | cut -d'|' -f2 | tr '\n' ' ' | sed 's/ $//'; }
type_languages()  { type_stacks "$1" | cut -d'|' -f3 | tr '\n' ' ' | sed 's/ $//'; }

stack_row() { # $1 type, $2 framework
  printf '%s\n' "$APP_STACK_TABLE" | awk -F'|' -v t="$1" -v f="$2" '$1 == t && $2 == f { print; exit }'
}

# All of these take the RESOLVED (APP_TYPE, FRAMEWORK) pair.
framework_language()  { stack_row "$1" "$2" | cut -d'|' -f3; }
framework_aliases()   { stack_row "$1" "$2" | cut -d'|' -f4; }
framework_signature() { stack_row "$1" "$2" | cut -d'|' -f5; }
framework_scaffold()  { stack_row "$1" "$2" | cut -d'|' -f6; }
framework_workflows() { stack_row "$1" "$2" | cut -d'|' -f7; }
framework_summary()   { stack_row "$1" "$2" | cut -d'|' -f8; }

# Which type owns a framework NAME. Languages and their aliases are deliberately
# NOT consulted: 'ruby' builds a Sinatra service and a gem-layout CLI, so it
# cannot identify a type on its own — resolve_app_type says so rather than
# picking one. Framework names are unique across the table, which is what makes
# `FRAMEWORK=zola` alone still mean "a service".
framework_owner() { # $1 framework -> the type, or empty
  printf '%s\n' "$APP_STACK_TABLE" | awk -F'|' -v k="$1" '$2 == k { print $1; exit }'
}

# The framework a user's token names WITHIN a type: its own name first, then an
# alias, then a language. Ordered so an exact framework name always wins.
resolve_framework() { # $1 type, $2 token -> the framework, or empty
  printf '%s\n' "$APP_STACK_TABLE" | awk -F'|' -v t="$1" -v k="$2" '
    $1 != t { next }
    $2 == k { print $2; exit }
    { n = split($4, a, " "); for (i = 1; i <= n; i++) if (a[i] == k) { print $2; exit } }
    $3 == k { print $2; exit }'
}

# Is this token one of the type's languages? Used by the argument parser to
# decide whether `--cli ruby` names a language or an app directory.
is_language_of() { # $1 type, $2 token
  case " $(type_languages "$1") " in *" $2 "*) return 0 ;; esac
  # An alias counts too: `--cli ts` and `--cli node` should read the same way
  # `--cli typescript` does.
  printf '%s\n' "$APP_STACK_TABLE" | awk -F'|' -v t="$1" -v k="$2" '
    $1 == t { n = split($4, a, " "); for (i = 1; i <= n; i++) if (a[i] == k) { found = 1 } }
    END { exit !found }'
}

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
  local t flag droplet db wf summary
  printf '%s\n' "$APP_TYPE_TABLE" | while IFS='|' read -r t flag droplet db wf summary; do
    printf '  %-9s %-11s %s\n' "$t" "$flag" "$summary"
    printf '  %-9s %-11s languages: %s (droplet: %s)\n' '' '' "$(type_languages "$t")" "$droplet"
  done
}

# Grouped by type, because the language column only means anything within one.
app_stack_help() {
  local t flag droplet db wf summary f lang aliases sig scaffold wfs fsummary
  printf '%s\n' "$APP_TYPE_TABLE" | while IFS='|' read -r t flag droplet db wf summary; do
    printf '  %s (%s):\n' "$t" "$flag"
    type_stacks "$t" | while IFS='|' read -r _t f lang aliases sig scaffold wfs fsummary; do
      printf '    --lang %-11s FRAMEWORK=%-9s %s\n' "$lang" "$f" "$fsummary"
    done
  done
}

# The flags that select a droplet-free type, for error messages — derived from
# the table, so a row added later appears here without an edit.
droplet_free_flags() {
  printf '%s\n' "$APP_TYPE_TABLE" \
    | awk -F'|' '$3 == "no" { printf "%s%s", (n++ ? ", " : ""), $2 } END { print "" }'
}

# ---- resolution -----------------------------------------------------------------
#
# TWO QUESTIONS, resolved in this order — the type first, because a language
# only means something within one ('ruby' builds a Sinatra service, a gem-layout
# CLI, or eventually a gem, and which one depends entirely on the type).
#
# WHICH TYPE. In precedence order:
#   1. an explicit type — a flag (--cli, --library, --service) or APP_TYPE
#   2. an explicit FRAMEWORK, whose NAME belongs to exactly one type — so
#      `FRAMEWORK=zola` alone still means "build a service", and the single-axis
#      mental model that predates this file keeps working unchanged
#   3. the default, 'service' — what every app built before app types existed
#
# --no-droplet is a CONSTRAINT, not a fourth input: it asserts "whatever this
# is, it provisions no droplet". Alone it selects the default droplet-free type;
# with --cli (already droplet-free) it is satisfied and redundant; with a type
# that needs one it fails loudly rather than half-applying.
#
# WHICH STACK within it. In precedence order:
#   1. LANGUAGE — `--cli ruby`, `--cli=ruby`, `--lang ruby`, or LANGUAGE=ruby
#   2. FRAMEWORK — the stack's own name, an alias, or (again) its language
#   3. the type's default: the first row of the type in the stack table
APP_TYPE_DEFAULT=service
NO_DROPLET_DEFAULT_TYPE=library

# Set by bootstrap.sh's argument parsing, before resolve_app_type runs.
APP_TYPE_FLAG=""       # the type a flag selected; empty when none did
LANGUAGE_FLAG=""       # the language a flag selected; empty when none did
REQUIRE_NO_DROPLET=0   # 1 when --no-droplet was passed

resolve_app_type() {
  local requested src

  if [ -n "${APP_TYPE_FLAG:-}" ]; then
    requested="$APP_TYPE_FLAG"; src="$(type_flag "$APP_TYPE_FLAG")"
    [ -n "$src" ] || src="flag"
  elif [ -n "${APP_TYPE:-}" ]; then
    requested="$APP_TYPE"; src="APP_TYPE=$APP_TYPE"
  elif [ -n "${FRAMEWORK:-}" ]; then
    # By framework NAME or alias only — never by language. A language is shared
    # across types by design, so inferring from one would silently pick a type.
    requested="$(framework_owner "$FRAMEWORK")"
    if [ -z "$requested" ]; then
      # A bare language is the likely mistake here, and the fix is to say which
      # type was meant rather than to guess.
      local owners; owners="$(language_owners "$FRAMEWORK")"
      [ -z "$owners" ] \
        || fail "FRAMEWORK '$FRAMEWORK' is a LANGUAGE, and more than one app type builds in it ($owners).
       Name the type too: $(language_type_examples "$FRAMEWORK")"
      fail "unknown FRAMEWORK '$FRAMEWORK'. Known stacks:
$(app_stack_help)"
    fi
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

  resolve_stack
}

# The stack (i.e. FRAMEWORK) within the resolved type.
resolve_stack() {
  local want resolved

  # A language, however it was spelled, wins over a framework: it is the more
  # specific request, and the two can only disagree when both were given.
  want="${LANGUAGE_FLAG:-${LANGUAGE:-}}"
  if [ -n "$want" ]; then
    resolved="$(resolve_framework "$APP_TYPE" "$want")"
    [ -n "$resolved" ] \
      || fail "app type '$APP_TYPE' has no '$want' stack. It builds in: $(type_languages "$APP_TYPE")
$(app_stack_help)"
    # Naming both, in disagreement, is a contradiction rather than a preference.
    if [ -n "${FRAMEWORK:-}" ]; then
      local from_fw; from_fw="$(resolve_framework "$APP_TYPE" "$FRAMEWORK")"
      [ -z "$from_fw" ] || [ "$from_fw" = "$resolved" ] \
        || fail "language '$want' and FRAMEWORK '$FRAMEWORK' disagree: the first means '$resolved', the second '$from_fw'. Drop one."
    fi
    FRAMEWORK="$resolved"
  elif [ -n "${FRAMEWORK:-}" ]; then
    resolved="$(resolve_framework "$APP_TYPE" "$FRAMEWORK")"
    if [ -z "$resolved" ]; then
      # A framework from ANOTHER type gets its own message — "not valid for cli"
      # is unhelpful when the real answer is "that one builds a service".
      local owner; owner="$(framework_owner "$FRAMEWORK")"
      [ -z "$owner" ] \
        || fail "FRAMEWORK '$FRAMEWORK' builds a '$owner', not a '$APP_TYPE' (valid for $APP_TYPE: $(type_frameworks "$APP_TYPE"))"
      fail "app type '$APP_TYPE' has no '$FRAMEWORK' stack. Valid: $(type_frameworks "$APP_TYPE") (or --lang $(type_languages "$APP_TYPE"))"
    fi
    FRAMEWORK="$resolved"
  else
    # The type's default is the first row it has in the stack table.
    FRAMEWORK="$(type_stacks "$APP_TYPE" | head -1 | cut -d'|' -f2)"
    [ -n "$FRAMEWORK" ] || fail "app type '$APP_TYPE' has no stacks in scripts/app-types.sh"
  fi

  LANGUAGE="$(framework_language "$APP_TYPE" "$FRAMEWORK")"

  # The app's pipeline, by name, in its own repo. provider.sh polls, dispatches
  # and diagnoses THIS — so a droplet-free app's CI is watched by exactly the
  # machinery that watches a service's deploy.
  CI_WORKFLOW="$(type_workflow "$APP_TYPE")"
}

# The types that build in a given language, for the "which one did you mean?"
# message above.
language_owners() { # $1 language-or-alias
  printf '%s\n' "$APP_STACK_TABLE" | awk -F'|' -v k="$1" '
    $3 == k { print $1; next }
    { n = split($4, a, " "); for (i = 1; i <= n; i++) if (a[i] == k) { print $1; next } }' \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}

language_type_examples() { # $1 language -> "--cli ruby, --service ruby"
  local t out=""
  for t in $(language_owners "$1"); do out="$out${out:+, }$(type_flag "$t") $1"; done
  printf '%s' "$out"
}
