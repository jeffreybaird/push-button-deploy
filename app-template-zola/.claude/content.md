# Content — sections, pages, front matter

Everything under `content/` becomes the site's URL tree. Zola has exactly two
kinds of content, and most confusion comes from mixing them up.

## Sections vs pages

| | Section | Page |
|---|---|---|
| File | `_index.md` (that exact name) | any other `*.md` |
| Represents | a directory / listing | a single document |
| Template default | `section.html` | `page.html` |
| In templates | `section.pages`, `section.subsections` | `page.content`, `page.date`, … |

```
content/
  _index.md          ->  /               (the home section, renders index.html)
  about.md           ->  /about/
  blog/_index.md     ->  /blog/          (a section: lists the pages below it)
  blog/hello.md      ->  /blog/hello/
  blog/2024/_index.md -> /blog/2024/     (a subsection)
```

A directory **without** an `_index.md` still produces pages, but it has no
listing page — `/blog/` would 404 while `/blog/hello/` works. If you want a
listing, add `_index.md`.

## Front matter

TOML between `+++` fences, at the very top of the file:

```toml
+++
title = "Hello, world"
date = 2024-01-01                  # pages only; drives sorting and feeds
description = "Shown in listings and <meta name=description>"
draft = false                      # true = excluded unless `zola serve --drafts`
slug = "hello"                     # override the URL segment (default: filename)
path = "/custom/full/path"         # override the whole URL (use sparingly)
template = "special.html"          # override which template renders this
weight = 10                        # sort key when the section sorts by weight

[taxonomies]
tags = ["intro", "meta"]           # requires a matching [[taxonomies]] in config.toml

[extra]
cover = "images/cover.jpg"         # anything you want; reachable as page.extra.cover
+++
```

Section front matter takes different keys — the ones that control the listing:

```toml
+++
title = "Blog"
sort_by = "date"          # or "weight", "title", "none"
template = "section.html" # which template renders THIS listing
page_template = "page.html"  # default template for pages IN this section
paginate_by = 10          # turn the listing into paginated pages
transparent = false       # true: pages bubble up to the parent section
+++
```

## Which template renders what

Zola resolves in this order, first match wins:

1. `template` in the page's own front matter
2. `page_template` on the containing section (pages only)
3. `page.html` / `section.html`
4. For the home section (`content/_index.md`): **`index.html`**, not
   `section.html` — this is the one that surprises people.

## Summaries

`<!-- more -->` in the body splits it: everything before is `page.summary`, which
is what listings should render. Without the marker `page.summary` is empty, and a
listing that renders it shows nothing.

## Linking

Use `@/`-prefixed **content paths**, never hand-written URLs:

```markdown
See [the first post](@/blog/hello-world.md).
```

```jinja
<a href="{{ get_url(path='@/blog/hello-world.md') | safe }}">First post</a>
```

Zola resolves these at build time and **fails the build** if the target doesn't
exist — a broken internal link becomes a red deploy instead of a dead link on the
live site. A hardcoded `/blog/hello-world/` gets no such check.

For assets in `static/`, use `get_url(path='css/main.css')`. It applies the
build-time base URL, which the deploy sets from the real domain.

## Images and files

Two options:

- `static/images/foo.png` → served at `/images/foo.png`. Good for shared assets.
- **Colocated**: put `foo.png` next to `hello-world.md` inside a page bundle
  (`content/blog/hello-world/index.md` + `foo.png`). Reference it as `foo.png`.
  Keeps a post's assets with the post.

## Drafts

`draft = true` hides a page from builds. `zola serve --drafts` shows them
locally. The deploy never passes `--drafts`, so drafts cannot reach production —
that is deliberate, not an oversight to fix.
