# Design System

> Template — fill in with your project's design tokens, components, and tone. Replace every `<placeholder>`.

This file is the authoritative reference for all frontend work on `<project name>`. Read it before writing any template, component, or CSS. Follow conventions already established in the codebase — discover before building.

> **Baseline:** Phoenix 1.8 · Tailwind v4 · daisyUI v5 (default). Theme switching uses daisyUI's data-theme attribute on `<html>`, not Tailwind's `class="dark"`. Tokens are CSS custom properties — overridable per tenant.

---

## Identity

`<Project name>` is a `<one-sentence description of the product and audience>`.

Aesthetic: `<describe the intended look and feel — e.g., "clean and professional", "warm and editorial", "bold and playful">`. The user should feel `<emotional goal — e.g., "in control", "at home", "delighted">`.

Tone: `<adjectives — e.g., "direct, friendly, confident">`. Not `<what it should NOT feel like>`.

---

## Stack

- Elixir / Phoenix Framework
- Phoenix LiveView (server-rendered, real-time patches)
- Tailwind CSS v4 + `<component library, e.g., daisyUI v5 — or "none">`
- Alpine.js for client-only UI state
- `Phoenix.LiveView.JS` for server-aware transitions
- LiveView Hooks for complex JS behaviors
- `<Icon set, e.g., Heroicons>` (already bundled)
- Font sources: `<Google Fonts / self-hosted / system only>`. Custom font upload: `<supported / not supported>`.

---

## Codebase Conventions — Discover Before Building

Before creating any file or module, read the existing codebase to understand:
- How LiveView modules are named and where they live
- How function components are organized and imported
- How the router is structured and what `pipe_through`s exist
- How Ecto schemas and context modules are organized
- What layouts exist and how they are applied
- How authentication currently works

Follow existing conventions exactly. Do not introduce new organizational patterns unless none exist for the type of thing you are building.

---

## Color System

All colors are CSS custom properties. Use semantic token class names in all Tailwind utilities. Never use hardcoded hex, rgb, or raw color values in templates or component files. Define tokens with Tailwind v4's `@theme` directive — not in `tailwind.config.js`.

### daisyUI + Tailwind v4 theming (default)

Phoenix 1.8 generators ship Tailwind v4 + daisyUI v5 out of the box, including a `theme_toggle/1` component in `MyAppWeb.Layouts` ([`layouts.ex`](https://www.phoenixframework.org/blog/phoenix-1-8-released)). Tailwind v4 is **CSS-config-first** — there is no `tailwind.config.js`. Tailwind and daisyUI are configured with `@import`/`@plugin`/`@theme` directives inside `assets/css/app.css` ([daisyUI Phoenix install](https://daisyui.com/docs/install/phoenix/)).

**Switching themes** uses daisyUI's `data-theme` attribute on the `<html>` element — **not** Tailwind's `class="dark"`. The toggle persists the choice to `localStorage` and re-applies it on load. Themes are declared in the daisyUI `@plugin` config:

```css
/* assets/css/app.css */
@plugin "daisyui" {
  themes: light --default, dark --prefersdark;
}
```

- `--default` marks the theme applied when no `data-theme` is set.
- `--prefersdark` wires that theme to the OS `prefers-color-scheme: dark` media query — so dark mode follows the system preference until the user explicitly toggles.

**Customize** themes via this `@plugin` config (and `@theme` for raw tokens) in `app.css`, never in `tailwind.config.js`.

> **If this template opts OUT of daisyUI:** state it here. The pure CSS-custom-property token system below (`@theme` + `:root`) then stands alone, and theme switching is implemented by toggling `data-theme` (or a `.dark` class of your choosing) against your own variable blocks rather than daisyUI's built-in themes.

| Concern | daisyUI default (Phoenix 1.8) | Tailwind-only / opted-out |
|---|---|---|
| Dark mode switch | `data-theme` on `<html>` | `data-theme` or `.dark` against your own `:root` blocks |
| Theme declaration | daisyUI `@plugin` config in `app.css` | `@theme` + `@layer base` in `app.css` |
| OS preference | `--prefersdark` flag | manual `@media (prefers-color-scheme)` |
| Config location | `app.css` (CSS-first) | `app.css` (CSS-first) |

### Surface tokens

Define a layered surface scale (at minimum: page background, card/panel, raised element, overlay/modal).

| Token | Purpose | Value |
|---|---|---|
| `bg-bg` | Page background | `<oklch value>` |
| `bg-surface` | Cards, panels | `<oklch value>` |
| `bg-elevated` | Inputs, dropdowns | `<oklch value>` |
| `bg-overlay` | Modals, popovers | `<oklch value>` |

### Border tokens

| Token | Purpose | Value |
|---|---|---|
| `border-border` | Standard dividers | `<oklch value>` |
| `border-border-subtle` | Light separators | `<oklch value>` |
| `border-border-strong` | Emphasis | `<oklch value>` |

### Text tokens

| Token | Purpose | Value |
|---|---|---|
| `text-text-primary` | Main readable text | `<oklch value>` |
| `text-text-secondary` | Supporting text | `<oklch value>` |
| `text-text-muted` | Metadata, labels | `<oklch value>` |
| `text-text-disabled` | Inactive elements | `<oklch value>` |

### Accent tokens — `<tenant-overridable / fixed>`

| Token | Purpose | Value |
|---|---|---|
| `bg-accent` / `text-accent` | Primary brand color | `<oklch value>` |
| `bg-accent-hover` | Hover state | `<oklch value>` |
| `bg-accent-active` | Active/pressed state | `<oklch value>` |
| `bg-accent-subtle` | Tinted accent background | `<oklch value>` |
| `text-accent-text` | Text on accent backgrounds | `<oklch value>` |

### Semantic / status tokens

| Token | Purpose | Value |
|---|---|---|
| `bg-success` | Success state | `<oklch value>` |
| `bg-warning` | Warning state | `<oklch value>` |
| `bg-error` | Error / destructive state | `<oklch value>` |

### Multi-tenant theming (if applicable)

`<Describe how per-tenant color overrides work, or remove this section if the app is single-tenant.>`

If supporting per-tenant overrides: apply them via a scoping attribute on the `<html>` element (e.g., `data-theme`) with tenant-specific values injected as an inline `<style>` block in the root layout. Inline injection ensures zero-latency application — no network request before styles apply.

---

## Typography

### Roles

Define a small set of semantic font roles. Four common roles:

| Role | CSS variable | Purpose |
|---|---|---|
| Display | `--font-display` | `<e.g., hero headlines, feature titles>` |
| Body | `--font-body` | `<e.g., prose, descriptions, long-form text>` |
| UI | `--font-ui` | `<e.g., navigation, buttons, labels, form elements>` |
| Mono | `--font-mono` | `<e.g., codes, metadata, timestamps>` |

Adjust or collapse roles to match your actual needs — don't define a role you don't use.

### Usage rules

- Display: `<size range, weight range, tracking, leading — e.g., "tracking-tighter at large sizes, font-semibold maximum">`.
- Body: `<leading, minimum size — e.g., "leading-relaxed (1.6), text-base minimum">`.
- UI: `<case convention, tracking — e.g., "sentence case always, tracking-wide only on uppercase labels">`.
- Mono: `<size, color — e.g., "text-xs, text-text-muted by default">`.

### Font sources

**Approved `<Google Fonts / self-hosted>` families:**

- Display: `<family 1>`, `<family 2>`, `<family 3>`
- Body: `<family 1>`, `<family 2>`
- UI: `<family 1>`, `<family 2>`
- Mono: `<family 1>`, `<family 2>`

Always include `dns-prefetch`, `preconnect`, and `preload as="style"` before any external font stylesheet link. Use the print/onload pattern to avoid render-blocking, with a `<noscript>` fallback.

**System fallbacks (always present as CSS variable defaults):**

- Display: `<e.g., 'Georgia', 'Times New Roman', serif>`
- Body: `<e.g., 'Palatino Linotype', Georgia, serif>`
- UI: `system-ui, -apple-system, 'Segoe UI', sans-serif`
- Mono: `<e.g., 'Menlo', 'Monaco', monospace>`

---

## Spacing & Layout

`<Describe your spacing scale and layout system. Examples below — replace or remove as appropriate.>`

- Base unit: `<e.g., 4px (Tailwind default)>`
- Max content width: `<e.g., 1280px>`
- Page horizontal padding: `<e.g., "px-4 on mobile, px-8 on desktop">`
- Grid columns: `<e.g., "12-column on desktop, 4-column on mobile">`
- Standard section gap: `<e.g., "gap-6 between cards, gap-12 between sections">`

---

## Animation System

### Easing curves

Define named easing curves as CSS custom properties or document them here.

| Name | Curve | When to use |
|---|---|---|
| Enter | `<cubic-bezier>` | Elements appearing |
| Exit | `<cubic-bezier>` | Elements disappearing |
| Standard | `<cubic-bezier>` | On-screen movement |
| `<optional: spring, cinematic, etc.>` | `<cubic-bezier>` | `<use case>` |

### Duration scale

| Name | Duration | When to use |
|---|---|---|
| Instant | `<e.g., 100ms>` | Micro-interactions |
| Fast | `<e.g., 150ms>` | Hover states |
| Normal | `<e.g., 250ms>` | Overlays, dropdowns |
| Slow | `<e.g., 500ms>` | Page-level transitions |

### Rules

- Only animate `transform` and `opacity`. Never animate layout properties (width, height, margin, padding, top, left) — these trigger reflow.
- Use asymmetric timing: enter slightly faster than exit.
- Always respect `prefers-reduced-motion: reduce` — disable all transitions globally in your main CSS file. This is non-negotiable for WCAG 2.1 AA compliance.
- Loading skeletons use a shimmer sweep keyframe animation.
- Use `Phoenix.LiveView.JS` for show/hide tied to server events.
- Use Alpine.js `x-show` + `x-transition` for client-only UI state.
- Use LiveView Hooks for complex JS behaviors requiring fine-grained control.

### Decision rule: `Phoenix.LiveView.JS` vs Alpine `x-transition`

Pick the transition mechanism by **who owns the visibility/state**, and never apply both to the same element.

| State driver | Use | Why |
|---|---|---|
| Server-driven (assigns, `phx-` events, stream insert/remove) | [`Phoenix.LiveView.JS`](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.JS.html) + CSS transition classes | The transition stays in sync with the LiveView diff; no client state to drift |
| Client-only (dropdown open, local tab, hover popover — no server round-trip) | Alpine [`x-transition`](https://alpinejs.dev/directives/transition) | Pure DOM state; keeps trivial UI off the socket |

If an element's visibility is ever set by the server, drive its transition with `JS` so the two never fight over the DOM.

```heex
<%!-- ✅ Server-driven flash dismissal: JS.hide owns the transition --%>
<div id="flash" phx-click={JS.hide(transition: "fade-out")}>...</div>

<%!-- ✅ Client-only menu: Alpine owns the transition --%>
<div x-data="{ open: false }">
  <button @click="open = !open">Menu</button>
  <ul x-show="open" x-transition>...</ul>
</div>

<%!-- ❌ Both on one element: JS and Alpine fight over visibility/DOM --%>
<div phx-click={JS.toggle()} x-show="open" x-transition>...</div>
```

### Keyed comprehensions (LiveView 1.1)

For `:for` loops over dynamic **in-memory** collections (not streams), add `:key={item.id}` so the diff tracks items by identity instead of position — this keeps transitions and DOM state stable when the list reorders ([LiveView 1.1](https://www.phoenixframework.org/blog/phoenix-liveview-1-1-released)). Streams already key by DOM id, so this applies to plain assign-backed lists.

---

## Components

`<Document your reusable UI components. For each component, describe its purpose, variants, and composition rules. Example structure below — replace with your actual components.>`

### `<Component name — e.g., Card>`

Purpose: `<one-sentence description>`.

Variants:
- `<variant 1>` — `<when to use>`
- `<variant 2>` — `<when to use>`

Rules:
- `<rule 1 — e.g., "card layout footprint never changes on hover">`
- `<rule 2>`

Skeleton: Every component that loads async must have a corresponding skeleton variant that matches the outer dimensions exactly.

### `<Component name — e.g., Button>`

Purpose: `<one-sentence description>`.

Variants: `<primary, secondary, ghost, destructive — or your actual set>`.

Rules:
- `<e.g., "always use <button> element, never <div> or <span> with click handlers">`
- `<e.g., "icon-only buttons require aria-label">`

### `<Add more components as needed>`

---

## Iconography

Icon set: `<e.g., Heroicons, Phosphor, Lucide — or custom>`.

Rules:
- Icon-only controls (buttons/links without visible text) must always have `aria-label`.
- Use `<size convention — e.g., "size-5 (20px) as default, size-4 for compact, size-6 for emphasis">`.
- `<Decorative icons: describe when to use aria-hidden="true">`.

---

## Page Surfaces

`<Document the key surfaces / page types in your application. For each, describe layout, key components, and important UX rules. Examples below.>`

### `<Surface name — e.g., Dashboard>`

`<Layout description, key components, empty states, loading states.>`

### `<Surface name — e.g., Auth flow>`

`<Layout, form structure, error message conventions — e.g., "error messages are specific, not generic".>`

### `<Surface name — e.g., Detail / modal>`

`<Entry trigger, layout, exit behavior — e.g., "closes on backdrop click and Escape key".>`

### Navigation

Desktop: `<describe — e.g., "sticky top bar with logo, nav links, user menu">`.
Mobile: `<describe — e.g., "fixed bottom dock with icon tabs">`.

Both must use semantic token colors and keyboard-navigable focus management.

---

## CSS Architecture

All token definitions live in the main CSS file using Tailwind v4's `@theme` directive and `@layer base`. Do not use `tailwind.config.js` for token definitions.

Required keyframes: `<shimmer (skeleton), fade-in, slide-up — list any others you define>`.

`prefers-reduced-motion: reduce` must disable all transitions and animations globally. This is non-negotiable.

Global base styles: `<color-scheme preference, text rendering, scrollbar styling, focus ring style>`.

---

## Tone of Voice

`<Describe how your application speaks to users. Fill in the sections below.>`

### Principles

- `<Principle 1 — e.g., "Be direct. Say what you mean in the fewest words.">`.
- `<Principle 2 — e.g., "Be human. Avoid jargon and corporate-speak.">`.
- `<Principle 3 — e.g., "Be specific in errors. Tell the user what happened and what to do next.">`.

### Error messages

Write errors that explain what happened and what the user can do. Avoid generic messages like "Something went wrong" or "Authentication failed" when you can be specific.

| Situation | `<Bad — don't write this>` | `<Good — write this instead>` |
|---|---|---|
| `<e.g., login failure>` | `<e.g., "Authentication failed">` | `<e.g., "No account found with that email">` |
| `<e.g., form validation>` | `<e.g., "Invalid input">` | `<e.g., "Email must include an @ symbol">` |

### Empty states

Every list or collection surface must have an empty state. Empty states should: `<describe tone — e.g., "be encouraging, not apologetic">`. Include: `<a brief label, optional supporting text, and a primary CTA where appropriate>`.

### Button and label copy

- `<e.g., "Use verbs for actions: 'Save changes' not 'Submit'">`.
- `<e.g., "Use sentence case, not Title Case, for all labels">`.
- `<e.g., "Avoid 'click here' — use descriptive link text">`.

---

## Accessibility Notes

These complement WCAG 2.1 AA requirements. Accessibility violations are bugs, not nice-to-haves.

- Use semantic HTML over ARIA. Use `<button>`, `<a>`, `<nav>`, `<main>` etc. Never attach click handlers to `<div>` or `<span>`.
- All interactive elements must be reachable via keyboard (Tab, arrow keys where appropriate).
- Visible focus indicators are required — never remove outlines without a visible replacement.
- Color contrast: text ≥ 4.5:1, large text ≥ 3:1, UI boundaries ≥ 3:1 (WCAG AA minimums). Never convey information by color alone.
- Every `<img>` must have `alt`. Decorative images use `alt=""`.
- Every form input must have a linked `<label>`. Errors linked via `aria-describedby`. Required fields marked with `required` or `aria-required`.
- Dynamic content (flash messages, loading states) must use `aria-live` regions.
- Touch targets minimum 44×44 CSS pixels.
- Auto-advancing content must respect `prefers-reduced-motion` and provide a visible pause control.

---

## Absolute Rules — Never Violate

- Never use hardcoded hex, rgb, or raw color values in templates or components — always use semantic tokens.
- Never use `tailwind.config.js` for token definitions — use `@theme` in CSS.
- Never animate layout properties (width, height, margin, padding, top, left).
- Never use placeholder-only form labels — always use visible `<label>` elements.
- Never use `phx-click` on `<div>` or `<span>` — use `<button>` or `<a>`.
- Never use an icon-only button or link without `aria-label`.
- Never remove focus outlines without a visible replacement.
- Never skip `prefers-reduced-motion` support on animated content.
- `<Add project-specific rules here>`.
