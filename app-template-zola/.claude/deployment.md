# Deployment — Zola via push-button-deploy

Every push to `main` builds this site in CI and publishes it to a DigitalOcean
droplet. You do not run `zola build` by hand for production, and you never copy
files to the server yourself.

## The pipeline

```
push to main
  -> checkout (submodules: recursive — themes are submodules)
  -> read .zola-version, install that Zola release
  -> zola build --base-url https://<DOMAIN>        <- THE GATE
  -> tar public/ -> scp to the droplet
  -> extract into /root/apps/<slug>/releases/<sha>
  -> ensure the shared Caddy + this site's route (edge.sh)
  -> publish.sh <sha>: flip `current` symlink, prune old releases
```

There is no test job. A broken template, an unresolvable `@/` link or invalid
front matter fails `zola build`, the job stops, and **nothing is uploaded** — the
previously published release keeps serving.

## On the droplet

```
/root/caddy/                 the SHARED edge proxy — ONE per droplet, owns :80/:443
  Caddyfile                  imports sites/*.caddy
  sites/<slug>.caddy         this site's route: root * /srv/<slug>/current
/root/apps/<slug>/
  releases/<sha>/            one directory per deployed commit (the built site)
  current -> releases/<sha>  the symlink Caddy serves through
  publish.sh                 flips that symlink
```

`/root/apps` is bind-mounted into the Caddy container at `/srv`, so the site file
points at `/srv/<slug>/current`. The symlink is **relative** so it resolves the
same inside the container and on the host.

The droplet may host other apps — dynamic ones (Phoenix, Sinatra) run containers
behind the same Caddy. Each app has its own directory, its own site file, and
cannot see the others.

## Publishing is a symlink move

`publish.sh` does `ln -s` to a temp name then `mv -Tf` over `current` — a single
`rename(2)`, so no request ever sees a missing or half-written root. Caddy
resolves `root` per request, so there is no reload and no restart. The switch is
instant and atomic.

It refuses to publish a release with no `index.html`, which is what an empty or
truncated upload looks like.

## Rollback

```bash
gh workflow run rollback.yml -f tag=<prior commit sha>
```

Old releases stay on disk, so this rebuilds and re-uploads nothing — it is the
same symlink flip pointed at an older directory. The window is however many
releases are kept (`KEEP_RELEASES` in `publish.sh`, default 5). Beyond that,
re-deploy the commit instead.

## Changing the Zola version

Edit `.zola-version` and push. CI downloads that release from GitHub and fails
loudly if it isn't a real one. The workflow has no version of its own.

## Themes

Standard Zola practice: add the theme as a git submodule under `themes/` and set
`theme = "..."` in `config.toml`. CI checks out with `submodules: recursive`, so
this works with no pipeline change. A theme added by *copying* files works too —
it just stops tracking upstream.

## Custom domains and the base URL

`DOMAIN` is a repo variable, set by the bootstrap from the DNS record it created.
The deploy passes it as `--base-url`, so:

- Nothing in `config.toml` or the templates should hardcode the production URL.
- Always build URLs with `get_url()` / `permalink`.
- `base_url` in `config.toml` matters only for local `zola serve`.

## Files you don't hand-edit

`deploy/*`, `.github/workflows/*` — managed by the push-button-deploy tooling and
overwritten when the bootstrap runs again. If you change one, understand the
release/symlink contract first: a `publish.sh` that isn't atomic, or a site file
that points somewhere else, takes the site down.

## When something is wrong

| Symptom | Look at |
|---|---|
| Deploy red before upload | the `Build site` step — a Tera or content error, quoted verbatim |
| 404 on every page | did `publish.sh` run? `ls -l /root/apps/<slug>/current` |
| Old content still serving | the symlink didn't move; check the `Publish release` step |
| TLS/cert errors | shared Caddy logs: `cd /root/caddy && docker compose logs caddy` |
| Broken internal link | it would have failed the build — check for a hardcoded URL that bypassed `@/` |
