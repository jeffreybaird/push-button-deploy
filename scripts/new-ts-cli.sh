#!/usr/bin/env bash
#
# new-ts-cli.sh — scaffold a TypeScript command-line program for Node. Invoked
# by bootstrap.sh's ensure_app for APP_TYPE=cli, LANGUAGE=typescript
# (`./bootstrap.sh --cli typescript <dir>`); also runnable by hand.
#
#   ./scripts/new-ts-cli.sh <app_dir>
#
# THE SHAPE: a library with an executable on top of it.
#
#   src/index.ts   the library — where the work happens, exported
#   src/cli.ts     argument parsing, and the shebang
#
# package.json's `bin` points at the compiled src/cli.js, so `npm i -g <name>`
# puts the command on your PATH while `import { … } from "<name>"` still gets
# the library. Same code, two ways in.
#
# ARGUMENTS ARE ARGUMENTS. Parsing is node:util's parseArgs — stdlib, so the
# whole tool has ZERO runtime dependencies. Long and short flags,
# `--flag value` and `--flag=value`, `--`, `--help`, `--version`, positionals
# and exit codes. Nothing is configured by exporting a variable in front of it.
#
# TypeScript is the only devDependency: `tsc` compiles src/ to dist/, and the
# tests are node:test (stdlib too) run against the compiled output — so `npm
# test` exercises exactly what ships. The test script globs the built files
# rather than passing `dist/`: node reports a bare directory as one opaque
# "ok 1 - dist", which says nothing about how many tests actually ran.
#
# WHY PURE BASH, with no `npm` involved: the same reason the other scaffolds
# are — the scaffold is written by hand and the build runs in CI, so
# `./bootstrap.sh --cli typescript` needs no local Node.
#
# Node version comes from NODE_VERSION, else the current LTS major.
#
# If <app_dir> already contains a package.json it is left alone.
#
# Portable: BSD/macOS bash, awk.
set -euo pipefail

fail() { printf 'new-ts-cli: %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }

APP_DIR="${1:-}"
[ -n "$APP_DIR" ] || fail "usage: new-ts-cli.sh <app_dir>"

APP_NAME="$(basename "$APP_DIR")"
# npm package names allow hyphens, and `my-tool` is the natural spelling for a
# command; nothing here derives an identifier from the name.
case "$APP_NAME" in
  [a-z]*[!a-z0-9_-]*|*[!a-z0-9_-]*|[!a-z]*)
    fail "app name '$APP_NAME' must be lowercase letters, digits, '_' or '-' (start with a letter): the dir basename names the package and the command" ;;
esac
NODE_PIN="${NODE_VERSION:-22}"

if [ -f "$APP_DIR/package.json" ]; then
  log "package.json already in $APP_DIR — leaving it alone"
  exit 0
fi
[ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ] \
  && fail "$APP_DIR is not empty and has no package.json — refusing to scaffold over it"

log "scaffolding TypeScript CLI '$APP_NAME' in $APP_DIR — node $NODE_PIN"
mkdir -p "$APP_DIR/src"

printf '%s\n' "$NODE_PIN" > "$APP_DIR/.node-version"
printf '%s\n' "$APP_NAME" > "$APP_DIR/.app-name"

cat > "$APP_DIR/.gitignore" <<'EOF'
/node_modules/
/dist/
/coverage/
*.tsbuildinfo
.env
EOF

cat > "$APP_DIR/package.json" <<EOF
{
  "name": "$APP_NAME",
  "version": "0.1.0",
  "description": "TODO: one sentence describing $APP_NAME.",
  "license": "MIT",
  "type": "module",
  "bin": {
    "$APP_NAME": "dist/cli.js"
  },
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "files": [
    "dist/cli.js",
    "dist/index.js",
    "dist/index.d.ts"
  ],
  "engines": {
    "node": ">=20"
  },
  "scripts": {
    "build": "tsc -p tsconfig.json && chmod +x dist/cli.js",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "test": "npm run build && node --test \"dist/**/*.test.js\""
  },
  "devDependencies": {
    "typescript": "^5.9.0",
    "@types/node": "^22.0.0"
  }
}
EOF

cat > "$APP_DIR/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "rootDir": "src",
    "outDir": "dist",
    "declaration": true,
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "verbatimModuleSyntax": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
EOF

# ---- the library -----------------------------------------------------------------
cat > "$APP_DIR/src/index.ts" <<EOF
/**
 * $APP_NAME — replace this with what the tool actually does.
 *
 * Keep the work in here, in functions that take arguments and return values.
 * src/cli.ts is a thin translation layer over this file, which is what lets the
 * same code be both \`import { greet } from "$APP_NAME"\` and
 * \`$APP_NAME --format json\` in a shell.
 */

export type Format = "text" | "json";

export const FORMATS: readonly Format[] = ["text", "json"];

export function isFormat(value: string): value is Format {
  return (FORMATS as readonly string[]).includes(value);
}

/**
 * An example of the shape: takes what it needs, returns a string, knows nothing
 * about argv, stdout or exit codes.
 *
 *     greet(["world"], "text")  // => "hello world"
 */
export function greet(words: readonly string[], format: Format = "text"): string {
  const subject = words.length === 0 ? "world" : words.join(" ");
  switch (format) {
    case "text":
      return \`hello \${subject}\`;
    case "json":
      return JSON.stringify({ greeting: "hello", subject });
  }
}
EOF

# ---- the executable --------------------------------------------------------------
cat > "$APP_DIR/src/cli.ts" <<EOF
#!/usr/bin/env node
/**
 * Argument parsing, and nothing else.
 *
 * \`run\` returns what to print and what status to exit with, rather than
 * printing and exiting itself — which is what lets the tests call it directly
 * instead of spawning a process.
 */
import { parseArgs } from "node:util";
import { createRequire } from "node:module";
import { FORMATS, greet, isFormat } from "./index.js";

const require = createRequire(import.meta.url);
// One source of truth for the version: package.json, the same string npm
// publishes. Read at runtime so it can never drift from what was released.
const { version } = require("../package.json") as { version: string };

export interface Result {
  stdout: string;
  stderr: string;
  /** 0 ran fine, 1 ran and failed, 2 you typed it wrong. */
  status: 0 | 1 | 2;
}

const USAGE = \`$APP_NAME \${version} — TODO: one sentence describing what it does.

Usage:
  $APP_NAME [options] [words...]

Options:
  -f, --format FORMAT   output format: \${FORMATS.join(" or ")} (default: text)
  -h, --help            print this message
  -v, --version         print the version

Examples:
  $APP_NAME hello there
  $APP_NAME --format json hello there
  $APP_NAME -f json -- --not-a-flag\`;

export function run(argv: readonly string[]): Result {
  let values: { format?: string; help?: boolean; version?: boolean };
  let positionals: string[];

  try {
    // parseArgs handles --flag value, --flag=value, -f value, -fvalue, bundled
    // short flags and \`--\`, and throws on anything it does not recognise.
    ({ values, positionals } = parseArgs({
      args: [...argv],
      options: {
        format: { type: "string", short: "f", default: "text" },
        help: { type: "boolean", short: "h", default: false },
        version: { type: "boolean", short: "v", default: false },
      },
      allowPositionals: true,
    }));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { stdout: "", stderr: \`\${message}\n\n\${USAGE}\n\`, status: 2 };
  }

  if (values.help) return { stdout: \`\${USAGE}\n\`, stderr: "", status: 0 };
  if (values.version) return { stdout: \`$APP_NAME \${version}\n\`, stderr: "", status: 0 };

  const format = values.format ?? "text";
  if (!isFormat(format)) {
    return {
      stdout: "",
      stderr: \`$APP_NAME: unknown format: \${format} (expected \${FORMATS.join(" or ")})\n\`,
      status: 2,
    };
  }

  return { stdout: \`\${greet(positionals, format)}\n\`, stderr: "", status: 0 };
}

// Only when actually run as the command — importing this module (the tests do)
// must not print anything or exit.
if (process.argv[1] && import.meta.url === \`file://\${process.argv[1]}\`) {
  const result = run(process.argv.slice(2));
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  process.exit(result.status);
}
EOF

# ---- tests -----------------------------------------------------------------------
cat > "$APP_DIR/src/cli.test.ts" <<EOF
import { test } from "node:test";
import assert from "node:assert/strict";
import { run } from "./cli.js";
import { greet } from "./index.js";

test("greet joins the words it is given", () => {
  assert.equal(greet(["hi", "there"]), "hello hi there");
});

test("greet defaults to the world", () => {
  assert.equal(greet([]), "hello world");
});

test("greet renders json", () => {
  assert.equal(greet(["you"], "json"), '{"greeting":"hello","subject":"you"}');
});

test("--help prints usage and exits 0", () => {
  const result = run(["--help"]);
  assert.equal(result.status, 0);
  assert.match(result.stdout, /Usage:/);
});

test("--version prints the version", () => {
  const result = run(["--version"]);
  assert.equal(result.status, 0);
  assert.match(result.stdout, /$APP_NAME \\d+\\.\\d+\\.\\d+/);
});

test("--format takes a value with a space", () => {
  const result = run(["--format", "json", "you"]);
  assert.equal(result.status, 0);
  assert.match(result.stdout, /"subject":"you"/);
});

test("--format=value works too", () => {
  const result = run(["--format=json", "you"]);
  assert.equal(result.status, 0);
  assert.match(result.stdout, /"subject":"you"/);
});

test("the short flag works", () => {
  const result = run(["-f", "json"]);
  assert.equal(result.status, 0);
  assert.match(result.stdout, /"subject":"world"/);
});

test("positional arguments reach the library", () => {
  assert.equal(run(["hi", "there"]).stdout.trim(), "hello hi there");
});

test("-- ends the options", () => {
  assert.equal(run(["--", "--format"]).stdout.trim(), "hello --format");
});

test("an unknown option exits 2 and says which", () => {
  const result = run(["--nope"]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /--nope/);
});

test("an unknown format exits 2", () => {
  const result = run(["--format", "yaml"]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /yaml/);
});
EOF

cat > "$APP_DIR/README.md" <<EOF
# $APP_NAME

TODO: one sentence describing $APP_NAME.

## Run it

    npm install
    npm run build
    ./dist/cli.js --help
    ./dist/cli.js --format json hello there

Installed (\`npm i -g $APP_NAME\`, or \`npm link\` from a checkout) it is just a
command:

    $APP_NAME --format json hello there

It takes **arguments**, not environment variables: \`--format json\`,
\`--format=json\`, \`-f json\` and \`--\` all work, \`--help\` and \`--version\` do what
you expect, and a usage error exits 2 rather than 1.

## Shape

\`src/index.ts\` is a library: exported functions that take arguments and return
values. \`src/cli.ts\` is the only part that knows about \`process.argv\`, and
package.json's \`bin\` points at its compiled output. So the same code is both
\`import { greet } from "$APP_NAME"\` and a command in a shell — and the tests
call the library directly rather than spawning a process.

Zero runtime dependencies: argument parsing is \`node:util\`'s \`parseArgs\` and
the tests are \`node:test\`, both stdlib. TypeScript is the only devDependency.

## Develop

    npm install
    npm test          # builds, then runs node --test against dist/
    npm run typecheck

## Pipeline

Every push runs \`.github/workflows/ci.yml\` (or \`.gitea/workflows/ci.yml\`):
typecheck, build, tests, and a smoke test of the built command.

This project provisions no infrastructure — no droplet, no DNS, no database.
It was created with \`pbd bootstrap --cli typescript\`.
EOF

log "scaffolded $APP_DIR (typescript cli): src/cli.ts, src/index.ts, package.json"
