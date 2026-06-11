# Theming

> CSS-variable theming is universal; per-tenant theme loading is optional (include if multi-brand/multi-tenant).

Load this file when working on visual customization, template selection, or branding configuration.

See also: `design-system.md` for token conventions, `multi-tenancy.md` for per-tenant data scoping.

> **Baseline:** Phoenix 1.8 · Tailwind v4 · daisyUI v5 (default). Theme switching uses daisyUI's data-theme attribute on `<html>`, not Tailwind's `class="dark"`. Tokens are CSS custom properties — overridable per tenant.

---

## Approach

Theming uses **CSS custom properties** set dynamically from a stored theme configuration. Templates consume these variables — they never contain hardcoded colors, fonts, or spacing values.

This means a single CSS bundle serves all visual contexts. The only thing that changes per brand is the `:root` variable block injected into the layout.

- **Single-brand apps:** define CSS variables once in a static stylesheet or layout.
- **Multi-brand/multi-tenant apps:** load theme values from the DB per tenant and inject them at render time.

---

## daisyUI + Per-Tenant Overrides (default Phoenix 1.8 stack)

daisyUI is **not** a competing system to the inline-`<style>` `:root` approach below — they layer. daisyUI's tokens (`--color-primary`, `--color-base-100`, etc.) **are themselves CSS custom properties**, so per-tenant brand colors override them with exactly the same inline-`<style>` mechanism this file already uses.

Two layers, applied in order:

1. **Base layer — daisyUI `data-theme` (light/dark).** daisyUI ships `light` and `dark` themes selected via `data-theme` on `<html>` (see `design-system.md` → *daisyUI + Tailwind v4 theming*; [Phoenix 1.8](https://www.phoenixframework.org/blog/phoenix-1-8-released), [daisyUI Phoenix](https://daisyui.com/docs/install/phoenix/)). This gives every tenant a working light/dark foundation for free.
2. **Brand layer — per-tenant CSS-variable override.** The server-rendered inline `<style>` block in the root layout overrides the relevant daisyUI custom properties with the tenant's stored brand values. Because these are plain CSS variables, the override wins without touching `app.css` or rebuilding assets.

```heex
<%!-- root layout: daisyUI base theme on <html>, tenant brand layered on top --%>
<html data-theme={@theme.base_theme || "light"}>
  <head>
    <style>
      :root {
        /* Override daisyUI's own tokens with tenant brand values */
        --color-primary:   <%= @theme.brand_primary %>;
        --color-secondary: <%= @theme.brand_secondary %>;
        --color-accent:    <%= @theme.accent %>;
        --color-base-100:  <%= @theme.surface %>;
      }
    </style>
  </head>
```

- `data-theme` chooses light vs dark (and respects `prefers-color-scheme` via the daisyUI `--prefersdark` flag).
- The inline `<style>` re-tints daisyUI's tokens per tenant — zero-latency, no extra request, no asset rebuild.
- daisyUI utility classes (`btn-primary`, `bg-base-100`, …) and your own semantic tokens both resolve to these variables, so the brand override propagates everywhere automatically.

> **If this template opts OUT of daisyUI:** none of the above applies. The pure CSS-custom-property approach in the next sections (your own `--brand-primary`, `--surface`, … overridden in the inline `<style>`) stands alone and is the whole theming story.

---

## Theme Schema (optional, multi-tenant)

If themes are stored per tenant, a schema like the following works well:

```elixir
schema "themes" do
  belongs_to :organization, MyApp.Accounts.Organization  # omit for single-brand

  # Colors
  field :brand_primary,   :string, default: "#1a73e8"
  field :brand_secondary, :string, default: "#174ea6"
  field :background,      :string, default: "#0f0f0f"
  field :surface,         :string, default: "#1a1a1a"
  field :text_primary,    :string, default: "#ffffff"
  field :text_secondary,  :string, default: "#a0a0a0"
  field :accent,          :string, default: "#e8901a"

  # Typography
  field :font_heading, :string, default: "Inter"
  field :font_body,    :string, default: "Inter"

  # Shape
  field :border_radius,      :string, default: "8px"
  field :card_border_radius, :string, default: "12px"

  # Assets
  field :logo_url,    :string
  field :favicon_url, :string

  timestamps()
end
```

---

## CSS Custom Properties

Inject theme values into the layout as `:root` variables. For single-brand apps, write these statically in `app.css`; for multi-tenant apps, render them server-side in the layout template.

```heex
<style>
  :root {
    --brand-primary:   <%= @theme.brand_primary %>;
    --brand-secondary: <%= @theme.brand_secondary %>;
    --bg:              <%= @theme.background %>;
    --surface:         <%= @theme.surface %>;
    --text-primary:    <%= @theme.text_primary %>;
    --text-secondary:  <%= @theme.text_secondary %>;
    --accent:          <%= @theme.accent %>;
    --font-heading:    '<%= @theme.font_heading %>', sans-serif;
    --font-body:       '<%= @theme.font_body %>', sans-serif;
    --radius:          <%= @theme.border_radius %>;
    --card-radius:     <%= @theme.card_border_radius %>;
  }
</style>
```

### Usage in components

All public-facing components reference these variables. Never use raw color values or Tailwind color classes for brand-specific styling.

```css
/* ✅ CORRECT */
.card {
  background: var(--surface);
  border-radius: var(--card-radius);
  color: var(--text-primary);
}

.btn-primary {
  background: var(--brand-primary);
}

/* ❌ WRONG — hardcoded values bypass theming */
.card {
  background: #1a1a1a;
  border-radius: 12px;
}
```

Tailwind is fine for layout utilities (flexbox, grid, spacing, responsive breakpoints). The restriction applies only to brand-customizable properties: colors, fonts, border radii, and similar visual identity elements.

---

## Templates

### Structure

Public-facing templates live in `lib/my_app_web/templates/`. Each template is a directory containing layout and component variant overrides.

```
lib/my_app_web/templates/
├── default/
│   ├── layout.html.heex
│   ├── home.html.heex
│   ├── card.html.heex
│   └── nav.html.heex
├── minimal/
│   ├── layout.html.heex
│   ├── home.html.heex
│   ├── card.html.heex
│   └── nav.html.heex
└── bold/
    ├── layout.html.heex
    ├── home.html.heex
    ├── card.html.heex
    └── nav.html.heex
```

### Template selection

The selected template name is stored on the theme record or on the organization. At render time, resolve the correct template directory from that value.

```elixir
defp template_path(context) do
  template_name = context.template || "default"
  "templates/#{template_name}"
end
```

### Template rules

- Every template must implement the same required files. If a template omits a file, fall back to `default/`.
- Templates control structure and layout only. All templates consume the same CSS custom properties for colors and typography.
- Templates never contain business logic — no Ecto queries, no API calls, no conditional rendering based on auth/subscription status. That logic lives in the LiveView or controller; the template only renders assigns.

---

## Admin Branding UI

The branding page in the admin dashboard (`/admin/branding`) allows an authorized user to:

1. Pick a template from available options (shown as previews)
2. Customize colors, fonts, and border radii via a visual editor
3. Upload a logo and favicon
4. Preview changes live before saving

The preview should use an `<iframe>` or a LiveView component that re-renders the public page with the draft theme applied, so the editor sees exactly what end users will see.

---

## Logo & Asset Storage

For an MVP, logos and favicons can be stored as URLs (the admin provides a hosted URL). For direct upload, integrate with an object store (Tigris, S3, or Cloudflare R2).

Do not store binary file data in Postgres.
