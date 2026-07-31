# Templates — Tera

Zola renders with [Tera](https://keats.github.io/tera/docs/), which is Jinja2-ish
but not Jinja2. The differences that bite are noted below.

## Inheritance

`base.html` defines blocks; every other template extends it and fills them.

```jinja
{% extends "base.html" %}
{% block title %}{{ page.title }} · {{ config.title }}{% endblock %}
{% block content %}
  <article>{{ page.content | safe }}</article>
{% endblock %}
```

`{% extends %}` must be the first tag in the file. A child template's content
outside a block is discarded — a common cause of "my markup vanished".

## What's in scope

Always: `config` (all of `config.toml`, including `config.extra.*`), plus
`current_path`, `current_url`, `lang`.

| Template | Also gets |
|---|---|
| `index.html` | `section` (the home section) |
| `section.html` | `section` — `.pages`, `.subsections`, `.content`, `.title` |
| `page.html` | `page` — `.content`, `.title`, `.date`, `.summary`, `.permalink`, `.extra`, `.taxonomies`, `.toc` |
| `taxonomy_list.html` / `taxonomy_single.html` | `taxonomy`, `term` |
| `404.html` | nothing page-specific — it is rendered once |

`section.pages` gives page objects, already ordered by the section's `sort_by`.

## Escaping — the one that catches everyone

Tera escapes HTML by default. Rendered Markdown is HTML, so **content needs
`| safe`**:

```jinja
{{ page.content | safe }}     {# correct #}
{{ page.content }}            {# renders escaped tags as visible text #}
```

Same for URLs from `get_url` used inside attributes: `{{ get_url(path='...') | safe }}`.

## Functions worth knowing

```jinja
{{ get_url(path="@/blog/post.md") }}      {# content path -> permalink; build fails if missing #}
{{ get_url(path="css/main.css") }}        {# static asset, base-url aware #}
{% set s = get_section(path="blog/_index.md") %}   {# pull another section's pages #}
{% set p = get_page(path="about.md") %}
{{ get_image_metadata(path="static/x.png").width }}
{% set data = load_data(path="data/things.toml") %}  {# toml/json/csv from the repo #}
```

`get_section` is how a home page lists posts that live elsewhere.

## Filters worth knowing

```jinja
{{ page.date | date(format="%B %e, %Y") }}
{{ section.pages | slice(end=5) }}
{{ posts | filter(attribute="extra.featured", value=true) }}
{{ posts | sort(attribute="title") }}
{{ page.content | striptags | truncate(length=160) }}
{{ value | default(value="fallback") }}
```

Note `default(value=...)` — Tera filters take **named** arguments, unlike Jinja's
positional ones.

## Shortcodes

A shortcode is a template in `templates/shortcodes/` callable from Markdown.
`templates/shortcodes/note.html`:

```jinja
<aside class="note">{{ body }}</aside>
```

Used in content:

```markdown
{% note() %}
Careful with this.
{% end %}
```

Self-closing form for shortcodes with no body: `{{ youtube(id="abc") }}`.
Arguments arrive as named variables; a body arrives as `body`.

## Debugging

- `zola serve` reloads templates on save and prints the Tera error with the
  offending line — read it, the messages are good.
- `{{ __tera_context }}` dumps everything in scope. Remove it before committing.
- A silently empty page is nearly always a missing `| safe`, a missing block, or
  a template that doesn't actually extend `base.html`.
