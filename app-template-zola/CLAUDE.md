# My Site

A static site built with **Zola** and deployed by **push-button-deploy**: every
push to `main` builds the site in CI, ships it to a DigitalOcean droplet as a
numbered release, and flips a symlink. A shared Caddy on that droplet serves the
files and terminates TLS.

There is no application server, no database and no container image. That is the
point — the whole runtime is "files on disk behind a web server".

## Layout

```
config.toml          site config (title, markdown options, [extra])
content/             the site's content tree — sections and pages, Markdown + TOML front matter
  _index.md          the home section
  blog/_index.md     a section (listing page)
  blog/*.md          pages in that section
templates/           Tera templates — base.html and the ones that extend it
static/              copied verbatim into the output root (css, images, files)
.zola-version        the Zola release CI builds with — bump it here, not in the workflow
deploy/              deploy-time files (Caddy site template, publish.sh, shared edge stack)
.github/workflows/   deploy + rollback pipelines
```

Build output goes to `public/`, which is **gitignored and never committed** — CI
rebuilds it on every deploy.

## Working on this site

```bash
zola serve          # live-reloading dev server on http://127.0.0.1:1111
zola build          # one-shot build into public/
zola check          # validate internal links and (optionally) external ones
```

The deploy runs `zola build --base-url https://<domain>`, so `base_url` in
`config.toml` only affects local `zola serve`. Never hardcode absolute URLs in
templates — use `get_url(path=...)` and `page.permalink`, which respect the
build-time base URL.

## Guides

- `.claude/content.md` — the content model: sections, pages, front matter, the
  rules that decide which template renders what.
- `.claude/templates.md` — Tera: inheritance, the variables in scope, the filters
  and functions worth knowing, and shortcodes.
- `.claude/deployment.md` — how a push becomes a live site, how rollback works,
  and what lives where on the droplet.

## The short rules

1. **Content is Markdown with TOML front matter.** The `+++` fence is required;
   `title` is effectively required for anything you link to.
2. **Never edit `public/`.** It is build output. Change `content/`, `templates/`
   or `static/`.
3. **Link between pages with `@/` paths** (`get_url(path="@/blog/post.md")` or a
   Markdown link to `@/blog/post.md`), not with hand-written URLs. Zola then
   fails the build on a broken internal link instead of shipping a dead one.
4. **A failed build blocks the deploy** — the live site keeps serving. There is
   no separate test suite; the build IS the gate.
5. **Bump Zola in `.zola-version`**, not in the workflow.
