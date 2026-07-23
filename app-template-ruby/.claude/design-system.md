# Design System

> Template — fill in with your project's design tokens, components, and tone. Replace every `<placeholder>` and the `MyApp` / `my_app` names.

This file is the authoritative reference for all frontend work on `<project name>`. Read it before writing any template, partial, view, or CSS. Follow conventions already established in the codebase — discover before building.

> **Baseline:** Plain CSS served as a static file from `public/css/` · CSS custom properties for tokens · ERB partials for reusable components · ERB templates rendered by modular Sinatra. Tokens are CSS variables — overridable per tenant. Tailwind is **optional** (a standalone CLI build step, below).

**Maturity tags:** **[core]** apply to every project · **[recommended]** strong default, skip only with reason · **[optional]** include only if the app needs it.

---

## Identity — fill in

`<Project name>` is a `<one-sentence description of the product and audience>`.

Aesthetic: `<describe the intended look and feel — e.g., "clean and professional", "warm and editorial", "bold and playful">`. The user should feel `<emotional goal — e.g., "in control", "at home", "delighted">`.

Tone: `<adjectives — e.g., "direct, friendly, confident">`. Not `<what it should NOT feel like>`.

---

## Stack **[core]**

| Concern | Sinatra |
|---|---|
| CSS delivery | Hand-authored CSS in `public/css/app.css`, served as a **static file** by Sinatra (`public/` is the static root). No asset pipeline, no fingerprinting by default. |
| Optional utility framework | **Tailwind via the standalone CLI binary** — no Node toolchain. Input `src/tailwind.css`, output `public/css/app.css` ([tailwindcss.com/blog/standalone-cli](https://tailwindcss.com/blog/standalone-cli)). Include only if the app wants utilities. |
| Build command | None by default (author CSS directly). With optional Tailwind: `./bin/tailwindcss -i src/tailwind.css -o public/css/app.css --watch` (dev), run alongside Puma via a `Procfile.dev`. |
| Reusable component | **ERB partial** in `views/components/`, rendered through a small helper on `App`. No ViewComponent gem — plain ERB + Ruby. |
| Template engine | ERB (`.erb`), rendered by Tilt via Sinatra's `erb` helper; layout `views/layout.erb`. |
| Client interactivity | Small **vanilla JS** in `public/js/`, progressive enhancement. No Hotwire/Turbo/Stimulus. |
| Icon set | `<e.g., inline SVG partials in views/components/icons/ / a downloaded SVG sprite>` |

- The default is **plain CSS you write and commit** — the file in `public/css/` is what ships; there is no compile step to forget. Reach for the optional Tailwind CLI only when a project genuinely wants utility classes.
- The standalone Tailwind CLI bundles v4 by default; pin the version you download so you know which directive set (`@theme` vs `tailwind.config.js`) applies.
- Font sources: `<Google Fonts / self-hosted under public/fonts/ / system only>`. Custom font upload: `<supported / not supported>`.

---

## Codebase Conventions — Discover Before Building **[core]**

Before creating any file, partial, or template, read the existing codebase to understand:

- How routes map to services and views (thin `get "/notes" do … end` blocks in `app.rb` / `app/routes/*.rb`), where partials live (`views/components/`), how `views/layout.erb` and shared partials are structured.
- Where CSS is served from (`public/css/app.css`) and, if the optional Tailwind CLI is in use, where its input lives and how the watcher is run.
- How authentication and the current-tenant lookup work — the `Current` module (`Current.user`, `Current.account`), set in a `before` filter — since per-tenant theming reads from it. See `.claude/multi-tenancy.md`.

Follow existing conventions exactly. Do not introduce new organizational patterns unless none exists for the type of thing you are building.

---

## Color & Token System **[core]**

All design values — colors, surfaces, accents, type scale, radii, spacing accents — are **CSS custom properties**. Use semantic token names in templates and component CSS. Never write hardcoded hex/rgb/raw color in a template, partial, or CSS rule.

### Where tokens live

Define tokens once in a **base layer** at the top of `public/css/app.css`, then reference them everywhere via `var(--token)`. This file is the single source of truth and is served directly — no build step required.

```css
/* public/css/app.css */

/* 1. Base token layer — single source of truth */
:root {
  --bg:            oklch(98% 0 0);
  --surface:       oklch(100% 0 0);
  --elevated:      oklch(96% 0 0);
  --text-primary:  oklch(20% 0 0);
  --text-secondary:oklch(45% 0 0);
  --text-muted:    oklch(60% 0 0);
  --border:        oklch(90% 0 0);
  --accent:        oklch(55% 0.2 250);
  --accent-text:   oklch(99% 0 0);
  --radius:        0.5rem;
}

/* 2. Component classes resolve to tokens — never raw color */
.card   { background: var(--surface); color: var(--text-primary);
          border: 1px solid var(--border); border-radius: var(--radius); }
```

If you opt into the **optional Tailwind CLI**, expose the same tokens to utilities instead of (or alongside) hand-written classes — the tokens stay the single switch point:

```css
/* src/tailwind.css — Tailwind v4 (CSS-first, no tailwind.config.js) */
@import "tailwindcss";
@theme {
  --color-bg:           var(--bg);
  --color-surface:      var(--surface);
  --color-text-primary: var(--text-primary);
  --color-accent:       var(--accent);
  --radius-md:          var(--radius);
}
```

```js
// Tailwind v3 alternative — tailwind.config.js
module.exports = {
  content: ["./views/**/*.erb", "./public/js/**/*.js"],
  theme: { extend: { colors: {
    bg: 'var(--bg)', surface: 'var(--surface)',
    'text-primary': 'var(--text-primary)', accent: 'var(--accent)',
  } } }
}
```

### Surface scale

| Token | Purpose | Value |
|---|---|---|
| `bg` | Page background | `<oklch value>` |
| `surface` | Cards, panels | `<oklch value>` |
| `elevated` | Inputs, dropdowns | `<oklch value>` |
| `overlay` | Modals, popovers | `<oklch value>` |

### Text scale

| Token | Purpose | Value |
|---|---|---|
| `text-primary` | Main readable text | `<oklch value>` |
| `text-secondary` | Supporting text | `<oklch value>` |
| `text-muted` | Metadata, labels | `<oklch value>` |

### Accent / brand — `<tenant-overridable / fixed>`

| Token | Purpose | Value |
|---|---|---|
| `accent` | Primary brand color | `<oklch value>` |
| `accent-hover` | Hover state | `<oklch value>` |
| `accent-text` | Text on accent backgrounds | `<oklch value>` |
| `accent-subtle` | Tinted accent background | `<oklch value>` |

### Status

| Token | Purpose | Value |
|---|---|---|
| `success` | Success state | `<oklch value>` |
| `warning` | Warning state | `<oklch value>` |
| `error` | Error / destructive state | `<oklch value>` |

```erb
<%# ✅ semantic token-backed class (defined in public/css/app.css) %>
<div class="card">…</div>

<%# ✅ same intent with optional Tailwind utilities resolving to the same tokens %>
<div class="bg-surface text-text-primary border border-border rounded-md">…</div>

<%# ❌ hardcoded color bypasses theming and per-tenant override %>
<div style="background:#1a1a1a;color:#fff;border-radius:12px">…</div>
```

Per-tenant brand overrides are documented in `.claude/theming.md` — the same `:root` variables are re-tinted at render time (a small `<style>` block driven by `Current.account`), so token-based components re-brand for free.

---

## Typography **[core]**

Define a small set of semantic font roles as CSS variables. Collapse roles you don't use.

| Role | Variable | Purpose |
|---|---|---|
| Display | `--font-display` | `<hero headlines, feature titles>` |
| Body | `--font-body` | `<prose, descriptions, long-form>` |
| UI | `--font-ui` | `<nav, buttons, labels, forms>` |
| Mono | `--font-mono` | `<codes, metadata, timestamps>` |

- Always declare **system fallbacks** in the variable default (e.g. `--font-ui: 'Inter', system-ui, sans-serif;`).
- Body: `<leading, min size — e.g., line-height 1.6, 1rem minimum>`.
- For external fonts, put `dns-prefetch` + `preconnect` + `preload as="style"` in `views/layout.erb` before the stylesheet `<link>`; provide a `<noscript>` fallback. Self-hosting under `public/fonts/` avoids the extra origin entirely. Avoid render-blocking.

---

## Components **[core]**

### ERB partials (reusable UI)

Use an **ERB partial** for any UI element reused across views, or any element with non-trivial variants. Partials live in `views/components/` and are rendered through a thin helper registered on `App`, keeping call sites terse and the class/variant logic in one place. Pass data in as **locals** — never query or branch on request state inside the partial.

```ruby
# app/helpers/component_helpers.rb
module ComponentHelpers
  BUTTON_VARIANTS = {
    primary: "btn--primary",
    ghost:   "btn--ghost",
  }.freeze

  def button_component(label:, variant: :primary, type: "button", **attrs)
    erb :"components/button", layout: false, locals: {
      label:         label,
      type:          type,
      variant_class: BUTTON_VARIANTS.fetch(variant),
      attrs:         attrs,
    }
  end
end
```

```ruby
# app.rb
class App < Sinatra::Base
  helpers ComponentHelpers
  # …
end
```

```erb
<%# views/components/button.erb — pure presentation, no logic %>
<button type="<%= type %>" class="btn <%= variant_class %>"
  <%= attrs.map { |k, v| %(#{k}="#{Rack::Utils.escape_html(v.to_s)}") }.join(" ") %>>
  <%= label %>
</button>
```

```erb
<%# call site %>
<%= button_component(label: "Save changes", variant: :primary, type: "submit") %>
```

- Use a **plain partial** (`erb :"components/badge", layout: false, locals: { … }`) for simple, logic-free fragments.
- Promote to a **helper-backed partial** (as above) when there are variants, conditional classes, or attribute plumbing worth naming once.
- Every behavior-bearing component ships with a test — exercise it through a Capybara feature spec that renders a view using it, selecting by `data-testid`. See `.claude/testing.md`. Per CLAUDE.md, every addition that adds behavior ships with a test.

---

## Semantic HTML over ARIA **[core]**

Use the right element; let the browser supply roles, focus, and keyboard handling for free. Sinatra hands you plain HTML — write real elements.

```erb
<%# ✅ real interactive elements %>
<a href="/orders/<%= order.id %>">View order</a>
<button type="button" data-testid="edit-order" data-modal-open="edit">Edit</button>

<%# ✅ a destructive action is a real <form> + <button>, not a link %>
<form method="post" action="/orders/<%= order.id %>">
  <input type="hidden" name="_method" value="delete">
  <button type="submit">Delete</button>
</form>

<%# ❌ click handler on a non-interactive element — no keyboard, no role %>
<div data-modal-open="edit">Edit</div>
<span onclick="…">Delete</span>
```

- Never put a click handler on `<div>`/`<span>`. Use `<button>`, `<a href>`, or a real `<form>` submit.
- State-changing actions (delete, publish) go through `<form method="post">`; use a hidden `_method` field for `PATCH`/`PUT`/`DELETE` — `Rack::MethodOverride` (enabled on `App`) rewrites the verb. Never mutate state on a `GET`.
- Use `<nav>`, `<main>`, `<header>`, `<footer>` for landmarks. Active nav links get `aria-current="page"`.
- See MDN for `<button>` vs `<a>` semantics ([developer.mozilla.org/en-US/docs/Web/HTML/Element/button](https://developer.mozilla.org/en-US/docs/Web/HTML/Element/button)).

---

## Animation **[core]**

- **Only animate `transform` and `opacity`.** Never animate layout properties (width, height, margin, padding, top, left) — they trigger reflow.
- Asymmetric timing: enter slightly faster than exit.
- **Respect `prefers-reduced-motion: reduce` — non-negotiable for WCAG 2.1 AA.** Disable transitions/animations globally:

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }
}
```

- Loading skeletons use a shimmer keyframe; their outer dimensions must match the loaded element.
- Drive show/hide from small vanilla JS in `public/js/` (a `data-*` hook wired on `DOMContentLoaded`) or, where possible, CSS-only `:target` / `<details>` — keep logic out of templates.

---

## Iconography **[core]**

- **Icon-only controls must have an accessible name** — `aria-label` on the `<button>`/`<a>`. Decorative icons get `aria-hidden="true"`.
- Default size `<e.g., 1.25rem (20px), class="icon">`; compact `<1rem, class="icon icon--sm">`; emphasis `<1.5rem, class="icon icon--lg">`.

```erb
<%# ✅ %><button type="button" aria-label="Close" data-modal-close><svg class="icon" aria-hidden="true">…</svg></button>
<%# ❌ %><button type="button"><svg class="icon">…</svg></button>
```

---

## Contrast & Forms **[core]**

- Text ≥ **4.5:1**, large text ≥ 3:1, UI boundaries ≥ 3:1 ([w3.org/WAI/WCAG21/quickref](https://www.w3.org/WAI/WCAG21/quickref/)). Never convey info by color alone.
- Every input has a linked `<label>` — plain HTML: `<label for="email">Email</label><input id="email" name="email">`. Errors via `aria-describedby`. Required fields marked.
- Touch targets ≥ 44×44 CSS px. Flash/loading regions use `aria-live`.

---

## Dark Mode + Theme Switch **[recommended]**

Theme selection is a **`data-theme` attribute on `<html>`** plus CSS-variable blocks — not a hardcoded class toggle. This keeps tokens as the single switch point and composes cleanly with per-tenant brand overrides (see `.claude/theming.md`).

```css
:root,
[data-theme="light"] { --bg: oklch(98% 0 0); --text-primary: oklch(20% 0 0); }
[data-theme="dark"]  { --bg: oklch(18% 0 0); --text-primary: oklch(96% 0 0); }

/* follow OS preference until the user explicitly chooses */
@media (prefers-color-scheme: dark) {
  :root:not([data-theme]) { --bg: oklch(18% 0 0); --text-primary: oklch(96% 0 0); }
}
```

Persist the choice in `localStorage` with a small vanilla JS file served from `public/js/`:

```js
// public/js/theme.js
(() => {
  const root = document.documentElement;
  const saved = localStorage.getItem("theme");
  if (saved) root.setAttribute("data-theme", saved);

  document.addEventListener("click", (e) => {
    if (!e.target.closest("[data-theme-toggle]")) return;
    const next = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
    root.setAttribute("data-theme", next);
    localStorage.setItem("theme", next);
  });
})();
```

```erb
<%# views/layout.erb: load once, defer so it never blocks render %>
<script src="/js/theme.js" defer></script>

<button type="button" data-theme-toggle aria-label="Toggle dark mode">…</button>
```

---

## Design Tokens & Tone — fill in **[core]**

> Replace this section with your project's concrete decisions.

### Spacing & layout
- Base unit: `<e.g., 4px scale>` · Max content width: `<e.g., 1280px>` · Page padding: `<e.g., 1rem mobile / 2rem desktop>`.

### Components inventory
For each reusable component document: purpose, variants, composition rules, skeleton.
- `<Card — purpose, variants, rules>`
- `<Button — variants: primary/secondary/ghost/destructive; always <button>/<a>/real form; icon-only needs aria-label>`

### Tone of voice
- Principles: `<be direct / be human / be specific in errors>`.
- Error copy: explain what happened + what to do. Avoid "Something went wrong." Surface service-object `Failure([:tag, …])` results as human sentences, not tags.

| Situation | ❌ Don't | ✅ Do |
|---|---|---|
| `<login failure>` | `<"Authentication failed">` | `<"No account found with that email">` |
| `<form validation>` | `<"Invalid input">` | `<"Email must include an @ symbol">` |

- Empty states: every list surface has one — encouraging, with a CTA.
- Buttons: verbs ("Save changes", not "Submit"); sentence case; no "click here".

---

## Absolute Rules — Never Violate **[core]**

- Never use hardcoded hex/rgb/raw color in templates or CSS rules — always semantic tokens.
- Never put click handlers on `<div>`/`<span>` — use `<button>`, `<a href>`, or a real `<form>` submit.
- Never mutate state on a `GET`; state-changing actions use `<form method="post">` (+ hidden `_method`).
- Never ship an icon-only control without `aria-label`.
- Never animate layout properties; never skip `prefers-reduced-motion`.
- Never remove focus outlines without a visible replacement.
- Never use placeholder-only labels — always a visible `<label>`.
- Never put business logic (Sequel queries, `Current`/policy checks) in a partial or ERB view — resolve it in the route/service and pass it in as locals.
- `<Add project-specific rules here>`.
</content>
</invoke>
