# App types

[← Docs index](index.md) · push-button-deploy

`service`, `cli` and `library` — the three shapes an app can take, and how to
select one.

## The three types

The **app type** is the *shape* of the thing being built, and therefore what
infrastructure it needs. The **language** is what it is written in, within that
shape. Each `(type, language)` pair also has a **framework** name — `sinatra`,
`ruby-cli`, `zola` — which is what `FRAMEWORK` takes.

| | `--service` (default) | `--cli` | `--no-droplet` (alias `--library`) |
|---|---|---|---|
| What it is | a web app served over HTTPS | a command-line program | a reusable package |
| Languages | `elixir`, `ruby`, `static` | `elixir`, `ruby`, `bash`, `typescript` | `elixir` |
| Frameworks | `phoenix`, `sinatra`, `zola` | `escript`, `ruby-cli`, `bash-cli`, `ts-cli` | `mix` |
| Droplet, DNS, TLS | yes | **none** | **none** |
| Database | `postgres` / `sqlite` / none | **none** | **none** |
| Container registry | yes (except `zola`) | **none** | **none** |
| PR staging | yes (except `zola`) | **none** | **none** |
| Credentials needed | DO + DNSimple + Spaces + SSH | **code host only** | **code host only** |
| Local tools | `mix` for Phoenix | `git`, `curl` | `git`, `curl` |
| Pipeline | `.github/workflows/deploy.yml` | `.github/workflows/ci.yml` | `.github/workflows/ci.yml` |
| The bootstrap ends when | `https://<domain>` answers | CI goes green | CI goes green |
| Teardown | droplet, DB, DNS, bucket, registry | nothing exists to destroy | nothing exists to destroy |

The droplet-free types (`cli`, `library`) are a genuinely smaller run: eight
steps instead of sixteen, no Terraform, no `doctl`, no SSH, and preflight asks
for the code host and nothing else. You can stand up a CLI on a laptop that has
never heard of DigitalOcean.

## Selecting a type

There are four ways to pick, resolved in this precedence order.

### 1. A type flag

`--service`, `--cli` and `--library` select the type directly. `--cli` and
`--service` also take the language on the same token:

```bash
./bootstrap.sh --cli ruby ~/src/mytool     # or --cli=ruby, or --cli --lang ruby
./bootstrap.sh --service ~/src/myapp        # the default, stated explicitly
./bootstrap.sh --help                       # the full list, rendered from the registry
```

### 2. A bare framework name

Because framework names are unique across the whole registry, naming one on its
own also picks the type:

```bash
FRAMEWORK=zola ./bootstrap.sh ~/src/myblog  # 'zola' belongs to service, so this is a service
```

A bare **language** does not pick a type: `FRAMEWORK=ruby` is ambiguous (Ruby
builds a Sinatra service *and* a gem-layout CLI) and the tool fails with a
message naming both, rather than guessing.

### 3. `--no-droplet` as a constraint

`--no-droplet` is a **constraint**, not a type of its own. It asserts "whatever
this is, it provisions no droplet."

- On its own it builds the default droplet-free type — a `library`.
- Alongside `--cli` it is already satisfied and does nothing.
- Against `--service` it **fails** rather than half-applying:

```
$ ./bootstrap.sh --no-droplet --service
bootstrap: --no-droplet conflicts with app type 'service' (a web app on its own droplet, ...).
       A 'service' is served from a droplet — there is no droplet-free variant of it.
       Drop the type flag (--no-droplet on its own builds a library), or name a
       droplet-free type: --cli, --library
```

"Deploy my Phoenix app without a server" and "build me a library instead" are
different requests, and guessing between them would hand you an app you didn't
ask for.

### 4. The default

With no type flag, no framework and no `--no-droplet`, the type is `service` —
what every app built before app types existed still gets.

## The interactive walkthrough

`--interactive` (short `-i`) picks the type and stack by menu instead of flags,
rendered from the registry so it always matches what is installed:

```bash
./bootstrap.sh -i ~/src/myapp
```

```
==> interactive setup — Enter accepts the [default] shown at each step

What are you building?
  *1) service    a web app on its own droplet, served over HTTPS
   2) cli        a command-line program — built, tested and packaged by CI
   3) library    a reusable package — built and tested by CI
choice [service]: 2

Which language?
  *1) elixir     one self-contained executable, via mix escript.build
   2) ruby       a gem-layout CLI on OptionParser, installable with gem install
   3) bash       a dependency-free shell CLI, shellcheck-clean
   4) typescript a Node CLI on node:util parseArgs, installable with npm i -g
choice [elixir]: ruby
...
```

Enter accepts the `[default]` (marked `*`); a menu choice takes either the number
or the name. The menu is rendered from the registry, so a stack added there shows
up here with no extra work. For a service it goes on to ask about the code host,
database, staging and tenancy — and can also tailor the
[Claude Code docs](claude-docs.md) the app gets.

## How to choose

- **Serving something over HTTP?** You want a `service`. Choose the framework in
  [Frameworks](frameworks.md) and the database in [Databases](databases.md).
- **Shipping a command people run?** You want a `cli`. Pick the language on the
  `--cli` flag; every stack ships real argument parsing (`--flag value`,
  `--help`, `--version`, exit codes) over its language's standard option parser.
- **Publishing a reusable package?** You want a `library` (`--no-droplet`).
  Today that is `mix`, an Elixir library.

Whatever you pick, the repo creation, pipeline wiring and one-command flow are
the same. See the [Reference](reference.md) for every flag and env var.
