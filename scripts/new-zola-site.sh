#!/usr/bin/env bash
#
# new-zola-site.sh — scaffold a runnable Zola site and drop in the Claude skill
# docs. The Zola counterpart to scripts/new-sinatra-app.sh (Sinatra) and
# scripts/inject-skill-docs.sh (Phoenix). Invoked by bootstrap.sh's ensure_app
# when FRAMEWORK=zola; also runnable by hand.
#
#   ./scripts/new-zola-site.sh <site_dir>
#
# What it does:
#   1. Derives SITE_SLUG (dir basename) + SITE_TITLE (a readable form of it).
#   2. Scaffolds a themeless Zola site: config.toml, a section-and-page content
#      tree with one post, Tera templates (base/index/section/page/404), a small
#      stylesheet, and .zola-version.
#   3. Copies the skill docs from app-template-zola/ (CLAUDE.md + .claude/*.md),
#      rewriting the my_site / My Site placeholders to the site's real names.
#
# NO LOCAL ZOLA REQUIRED. The scaffold is written by hand rather than by `zola
# init` precisely so the tool keeps its "empty directory to live site" promise
# without adding a binary to the preflight — the build happens in CI.
#
# If <site_dir> already contains a config.toml it is treated as an existing site:
# only step 3 (skill docs) runs, so it doubles as a retrofit for a site you wrote
# yourself or generated with `zola init`.
#
# Portable: BSD/macOS bash, awk, perl.
set -euo pipefail

fail() { printf 'new-zola-site: %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../app-template-zola"

# The Zola release CI installs. Overridable for a new site; an existing site's
# committed .zola-version always wins (it is never rewritten).
ZOLA_PIN="${ZOLA_VERSION:-0.19.2}"

SITE_DIR="${1:-}"
[ -n "$SITE_DIR" ] || fail "usage: new-zola-site.sh <site_dir>"
[ -f "$TEMPLATE_DIR/CLAUDE.md" ] || fail "no CLAUDE.md in $TEMPLATE_DIR"
[ -d "$TEMPLATE_DIR/.claude" ]   || fail "no .claude/ in $TEMPLATE_DIR"

SITE_SLUG="$(basename "$SITE_DIR")"
case "$SITE_SLUG" in
  # Letters, digits, _ and - only, starting with a letter: the basename becomes
  # the DNS label, the compose-free stack directory and the Caddy site file name.
  [a-z]*[!a-z0-9_-]*|*[!a-z0-9_-]*|[!a-z]*)
    fail "site name '$SITE_SLUG' must be lowercase letters, digits, '_' or '-' (start with a letter): the dir basename names the site" ;;
esac
# my_site / my-site -> My Site. Only a starting point; edit config.toml after.
SITE_TITLE="$(printf '%s' "$SITE_SLUG" | tr '_-' '  ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)}; print}')"

# ---- 1/2. scaffold the site (skipped when a config.toml already exists) --------
scaffold() {
  [ -d "$SITE_DIR" ] && [ -n "$(ls -A "$SITE_DIR" 2>/dev/null)" ] \
    && fail "$SITE_DIR is not empty and has no config.toml — refusing to scaffold over it"
  log "scaffolding Zola site '$SITE_SLUG' ($SITE_TITLE) in $SITE_DIR"
  mkdir -p "$SITE_DIR"/{content/blog,templates,static/css}

  printf '%s\n' "$ZOLA_PIN" > "$SITE_DIR/.zola-version"

  # base_url is a placeholder: the deploy passes --base-url "https://$DOMAIN", so
  # the committed value only matters to `zola serve` locally.
  cat > "$SITE_DIR/config.toml" <<TOML
# Zola configuration. Full reference: https://www.getzola.org/documentation/
#
# base_url is overridden at deploy time (\`zola build --base-url https://\$DOMAIN\`),
# so this value only affects local \`zola serve\`. Change the title and description
# — they are what the templates render.
base_url = "http://127.0.0.1:1111"
title = "$SITE_TITLE"
description = "A site built with Zola."

# Generate an Atom feed at /atom.xml from the blog section.
generate_feeds = true
feed_filenames = ["atom.xml"]

compile_sass = false
build_search_index = false

[markdown]
# Syntax highlighting for fenced code blocks.
highlight_code = true
highlight_theme = "base16-ocean-dark"
# Open external links safely; internal ones are checked at build time.
external_links_target_blank = true

[extra]
# Anything here is available in templates as config.extra.*
author = "$SITE_TITLE"
TOML

  cat > "$SITE_DIR/content/_index.md" <<'MD'
+++
title = "Home"
# The home page renders index.html, which lists the blog section below.
+++

Welcome. This is the home page — edit `content/_index.md` to change it.
MD

  cat > "$SITE_DIR/content/blog/_index.md" <<'MD'
+++
title = "Blog"
sort_by = "date"
template = "section.html"
page_template = "page.html"
# Every .md file in this directory becomes a page in this section.
+++

Posts, newest first.
MD

  cat > "$SITE_DIR/content/blog/hello-world.md" <<'MD'
+++
title = "Hello, world"
date = 2024-01-01
description = "The first post — delete it once you have a real one."

[taxonomies]
# tags = ["intro"]   # uncomment after declaring a `tags` taxonomy in config.toml
+++

This file is `content/blog/hello-world.md`. Everything above the `+++` fence is
**front matter** (TOML); everything below is Markdown.

<!-- more -->

Text after the `<!-- more -->` marker is excluded from `page.summary`, which is
what the section listing shows.

```rust
fn main() {
    println!("code blocks are syntax-highlighted at build time");
}
```
MD

  cat > "$SITE_DIR/templates/base.html" <<'HTML'
{# The shell every page extends. Blocks are the extension points. #}
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{% block title %}{{ config.title }}{% endblock %}</title>
  <meta name="description" content="{% block description %}{{ config.description }}{% endblock %}">
  <link rel="stylesheet" href="{{ get_url(path='css/main.css') | safe }}">
  {% if config.generate_feeds %}
  <link rel="alternate" type="application/atom+xml" title="{{ config.title }}"
        href="{{ get_url(path='atom.xml') | safe }}">
  {% endif %}
</head>
<body>
  <header class="site-header">
    {# | safe: Tera escapes by default, which would turn the // in the URL into
       entities. Every URL interpolated into an attribute needs it. #}
    <a class="site-title" href="{{ config.base_url | safe }}">{{ config.title }}</a>
    <nav>
      <a href="{{ get_url(path='@/blog/_index.md') | safe }}">Blog</a>
    </nav>
  </header>

  <main>
    {% block content %}{% endblock %}
  </main>

  <footer class="site-footer">
    <p>&copy; {{ now() | date(format='%Y') }} {{ config.extra.author }}</p>
  </footer>
</body>
</html>
HTML

  cat > "$SITE_DIR/templates/index.html" <<'HTML'
{% extends "base.html" %}

{% block content %}
  <article class="prose">
    {{ section.content | safe }}
  </article>

  {% set blog = get_section(path="blog/_index.md") %}
  <h2>Latest posts</h2>
  <ul class="post-list">
    {% for page in blog.pages | slice(end=5) %}
      <li>
        <a href="{{ page.permalink | safe }}">{{ page.title }}</a>
        <time datetime="{{ page.date }}">{{ page.date | date(format='%B %e, %Y') }}</time>
      </li>
    {% endfor %}
  </ul>
{% endblock %}
HTML

  cat > "$SITE_DIR/templates/section.html" <<'HTML'
{% extends "base.html" %}

{% block title %}{{ section.title }} · {{ config.title }}{% endblock %}

{% block content %}
  <h1>{{ section.title }}</h1>
  <div class="prose">{{ section.content | safe }}</div>

  <ul class="post-list">
    {% for page in section.pages %}
      <li>
        <a href="{{ page.permalink | safe }}">{{ page.title }}</a>
        <time datetime="{{ page.date }}">{{ page.date | date(format='%B %e, %Y') }}</time>
        {% if page.description %}<p>{{ page.description }}</p>{% endif %}
      </li>
    {% endfor %}
  </ul>
{% endblock %}
HTML

  cat > "$SITE_DIR/templates/page.html" <<'HTML'
{% extends "base.html" %}

{% block title %}{{ page.title }} · {{ config.title }}{% endblock %}
{% block description %}{{ page.description | default(value=config.description) }}{% endblock %}

{% block content %}
  <article class="prose">
    <h1>{{ page.title }}</h1>
    {% if page.date %}
      <time datetime="{{ page.date }}">{{ page.date | date(format='%B %e, %Y') }}</time>
    {% endif %}
    {{ page.content | safe }}
  </article>
{% endblock %}
HTML

  cat > "$SITE_DIR/templates/404.html" <<'HTML'
{# Served by Caddy with a 404 status — see deploy/site.caddy.tmpl. #}
{% extends "base.html" %}

{% block title %}Not found · {{ config.title }}{% endblock %}

{% block content %}
  <article class="prose">
    <h1>Not found</h1>
    <p>That page doesn't exist. <a href="{{ config.base_url | safe }}">Back home</a>.</p>
  </article>
{% endblock %}
HTML

  cat > "$SITE_DIR/static/css/main.css" <<'CSS'
/* Small, dependency-free baseline. Replace wholesale if you bring a design. */
:root {
  --fg: #1a1a1a;
  --muted: #666;
  --bg: #fdfdfc;
  --accent: #1e4fd8;
  --measure: 34rem;
}

@media (prefers-color-scheme: dark) {
  :root { --fg: #e8e8e6; --muted: #9a9a96; --bg: #16161a; --accent: #8fb0ff; }
}

* { box-sizing: border-box; }

body {
  margin: 0 auto;
  padding: 2rem 1.25rem 4rem;
  max-width: var(--measure);
  background: var(--bg);
  color: var(--fg);
  font: 1rem/1.65 ui-serif, Georgia, "Times New Roman", serif;
}

a { color: var(--accent); }

.site-header {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 1rem;
  margin-bottom: 3rem;
}

.site-title { font-weight: 600; text-decoration: none; }
.site-header nav a { margin-left: 1rem; }

h1, h2, h3 { line-height: 1.2; font-weight: 600; }

time { color: var(--muted); font-size: 0.875rem; }

.post-list { list-style: none; padding: 0; }
.post-list li { margin-bottom: 1.5rem; }
.post-list a { font-size: 1.125rem; text-decoration: none; }
.post-list p { margin: 0.25rem 0 0; color: var(--muted); }

.prose img { max-width: 100%; height: auto; }

.prose pre {
  padding: 1rem;
  overflow-x: auto;
  border-radius: 4px;
  font-size: 0.875rem;
}

.site-footer {
  margin-top: 4rem;
  padding-top: 1rem;
  border-top: 1px solid var(--muted);
  color: var(--muted);
  font-size: 0.875rem;
}
CSS

  cat > "$SITE_DIR/.gitignore" <<'GITIGNORE'
# Zola build output — rebuilt by CI on every deploy, never committed.
public/
# Zola's incremental-build cache.
.zola-cache
GITIGNORE
}

# ---- 3. skill docs ------------------------------------------------------------
inject_docs() {
  log "injecting Claude skill docs from $(basename "$TEMPLATE_DIR")/"
  mkdir -p "$SITE_DIR/.claude"
  local f base
  for f in "$TEMPLATE_DIR/CLAUDE.md" "$TEMPLATE_DIR"/.claude/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    if [ "$base" = "CLAUDE.md" ]; then
      perl -pe "s/\bMy Site\b/$SITE_TITLE/g; s/\bmy_site\b/$SITE_SLUG/g" "$f" > "$SITE_DIR/CLAUDE.md"
    else
      perl -pe "s/\bMy Site\b/$SITE_TITLE/g; s/\bmy_site\b/$SITE_SLUG/g" "$f" > "$SITE_DIR/.claude/$base"
    fi
  done
}

if [ -f "$SITE_DIR/config.toml" ]; then
  log "site: using existing $SITE_DIR (skipping scaffold)"
  # An existing site may predate .zola-version; CI requires it.
  if [ ! -f "$SITE_DIR/.zola-version" ]; then
    printf '%s\n' "$ZOLA_PIN" > "$SITE_DIR/.zola-version"
    log "wrote .zola-version ($ZOLA_PIN) — CI reads it to pin the build"
  fi
else
  scaffold
fi

inject_docs
log "done: $SITE_DIR"
