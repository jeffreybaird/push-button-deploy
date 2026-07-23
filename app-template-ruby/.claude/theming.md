# Theming

> CSS-variable theming is universal; per-tenant theme loading is optional (include if multi-brand/multi-tenant).

Load this file when working on visual customization, template/layout selection, or branding configuration.

See also: `.claude/design-system.md` for token conventions, `.claude/multi-tenancy.md` for per-tenant data scoping, `.claude/database.md` for Sequel migrations and the single-writer SQLite constraint.

> **Baseline:** Plain CSS served as a static file from `public/css/app.css` · CSS custom properties for tokens · ERB partials for reusable components · ERB templates rendered by modular Sinatra (`class App < Sinatra::Base`). Tokens are CSS variables — overridable per tenant. No asset pipeline, no ViewComponent.

**Maturity tags:** **[core]** apply to every project · **[recommended]** strong default, skip only with reason · **[optional]** include only if the app needs it (e.g. multi-tenant / multi-brand).

---

## Approach — CSS variables are the single customization point **[core]**

Theming is **CSS custom properties** set from a stored theme configuration. Templates and partials consume those variables; they never hold hardcoded colors, fonts, or radii.

This gives you **one CSS file for every brand**. The only thing that changes per brand or tenant is the `:root` / `[data-theme]` variable block injected into the layout. No rebuild, no per-tenant stylesheet — `public/css/app.css` is served directly as a static file.

- **Single-brand apps:** write the variable block once, statically, in the base token layer at the top of `public/css/app.css` (see `.claude/design-system.md`).
- **Multi-brand / multi-tenant apps:** load values from a stored `Theme` row per tenant and server-render them into the layout at request time.

```erb
<%# ✅ component reads variables — re-brands for free %>
<style>.card { background: var(--surface); border-radius: var(--radius); color: var(--text-primary); }</style>

<%# ❌ hardcoded — bypasses theming, cannot be overridden per tenant %>
<style>.card { background: #1a1a1a; border-radius: 12px; }</style>
```

Layout properties (flex, grid, spacing, breakpoints) may be plain CSS. The variable rule applies only to **brand-customizable** properties: colors, fonts, radii, and similar identity values.

---

## Per-tenant theming — server-render a `:root` block **[optional]**

For multi-tenant apps, render an inline `<style>` `:root` block in `views/layout.erb` from the tenant's stored `Theme`. Inline injection means **zero latency** — styles apply on first paint, no extra request, no flash of unbranded content.

Resolve the theme in the same `before` filter that sets the tenant (see `.claude/multi-tenancy.md`), then read it in the layout:

```ruby
# app.rb — modular Sinatra
class App < Sinatra::Base
  before do
    # Current.account is set from the request's tenant (see multi-tenancy.md).
    Current.theme = Current.account&.theme   # Sequel one_to_one; nil for single-brand apps
  end
  after { Current.reset }
end
```

```erb
<%# views/layout.erb — rendered by Sinatra's `erb` helper %>
<!DOCTYPE html>
<html data-theme="<%= (Current.theme && Current.theme.base_theme) || "light" %>">
  <head>
    <link rel="stylesheet" href="/css/app.css">
    <% if (theme = Current.theme) %>
      <style>
        :root {
          --accent:       <%= theme.brand_primary %>;
          --accent-2:     <%= theme.brand_secondary %>;
          --surface:      <%= theme.surface %>;
          --text-primary: <%= theme.text_primary %>;
          --font-body:    "<%= theme.font_body %>", system-ui, sans-serif;
          --font-display: "<%= theme.font_display %>", system-ui, sans-serif;
          --radius:       <%= theme.border_radius %>;
        }
      </style>
      <% if theme.favicon_url %><link rel="icon" href="<%= theme.favicon_url %>"><% end %>
    <% end %>
  </head>
  <body><%= yield %></body>
</html>
```

The raw interpolation above is safe **only because every field is validated on write** (see the schema below). Sinatra's ERB does **not** auto-escape by default (unlike Rails), and inside a `<style>` block HTML-escaping would not stop CSS or `</style>`-breakout injection anyway — the real defense is strict validation on write, so the model can only ever hold a hex/oklch color or an `https` URL. Never relax that validation to "escape it in the view instead."

This composes with the `data-theme` light/dark switch from `.claude/design-system.md`: `data-theme` picks the light/dark base, the inline `:root` block re-tints brand tokens on top.

---

## Theme schema **[optional]**

Store one row per tenant/brand. The fields map 1:1 to the CSS variables above. This is a Sequel migration — see `.claude/database.md` for the migration workflow (`rake db:migrate`, Sequel::Migrator).

```ruby
# db/migrate/010_create_themes.rb
Sequel.migration do
  change do
    create_table(:themes) do
      primary_key :id
      # omit account_id for single-brand apps; FK + index + cascade for multi-tenant
      foreign_key :account_id, :accounts, null: false, on_delete: :cascade, index: true

      # Colors — validated as hex/oklch on write
      String :brand_primary,   null: false, default: "#1a73e8"
      String :brand_secondary, null: false, default: "#174ea6"
      String :surface,         null: false, default: "#ffffff"
      String :background,      null: false, default: "#fafafa"
      String :text_primary,    null: false, default: "#111111"
      String :text_secondary,  null: false, default: "#555555"
      String :accent,          null: false, default: "#e8901a"
      String :base_theme,      null: false, default: "light"   # light | dark

      # Typography
      String :font_display, default: "Inter"
      String :font_body,    default: "Inter"

      # Shape
      String :border_radius,      default: "8px"
      String :card_border_radius, default: "12px"

      # Assets — object-store URLs, not blobs
      String :logo_url
      String :favicon_url

      # Structure
      String :template_name, null: false, default: "default"

      DateTime :created_at
      DateTime :updated_at
    end
  end
end
```

Validate on the model with `validation_helpers` — colors must match a hex/oklch shape, URLs must be `https`. Reject everything else so the inline `<style>` block can never carry an injection payload.

```ruby
# app/models/theme.rb
class Theme < Sequel::Model
  many_to_one :account
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  HEX   = /\A#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\z/
  HTTPS = %r{\Ahttps://}

  def validate
    super
    %i[brand_primary brand_secondary surface background
       text_primary text_secondary accent].each do |col|
      validates_format HEX, col, message: "must be a hex color"
    end
    validates_includes %w[light dark], :base_theme
    %i[logo_url favicon_url].each do |col|
      validates_format HTTPS, col, message: "must be an https URL" unless send(col).to_s.empty?
    end
  end
end
```

```ruby
# app/models/account.rb — the tenant owns one theme
class Account < Sequel::Model
  one_to_one :theme
end
```

---

## Asset storage — logos & favicons **[optional]**

**Never store binary file data in SQLite.** The database is a single file replicated to S3 (DO Spaces) by Litestream; blobs bloat every write, inflate the WAL, and slow the Litestream stream — and there is only **one writer** (see `.claude/database.md`). Store an object-store URL on the theme row instead.

| Upload mechanism | Reference |
|---|---|
| **MVP:** admin pastes a hosted `https` URL; validate and persist it in `logo_url` | plain form + the model validation above |
| **Direct upload:** a `StorageClient` presigns a `PUT` to S3 / DO Spaces; the client uploads; you persist the returned URL | `.claude/external-service-integration.md`, `.claude/object-storage-integration.md` |

```ruby
# app/services/themes/attach_logo.rb — presign + persist, keep the DB blob-free
module Themes
  class AttachLogo
    include Dry::Monads[:result]

    def self.call(theme:, io:, content_type:) = new.call(theme:, io:, content_type:)

    def call(theme:, io:, content_type:)
      key = "themes/#{theme.account_id}/logo-#{SecureRandom.hex(8)}"
      url = StorageClient.new.upload(key:, io:, content_type:)  # PUT to S3/DO Spaces
      theme.update(logo_url: url)
      Success(theme)
    end
  end
end
```

The layout only reads `theme.logo_url` / `theme.favicon_url`, so you can start with pasted URLs and wire direct upload later without touching a single view.

---

## Layout / template variants — structure only **[optional]**

A stored `template_name` selects which **layout ERB** wraps the view. Variants control **structure only** — they all consume the same CSS variables, so brand colors/fonts stay consistent across templates. Resolve the layout at render time from an allowlist; an unknown or missing name falls back to `default`.

```ruby
# app/helpers/layout_helpers.rb
module LayoutHelpers
  TEMPLATES = %w[default minimal bold].freeze

  def resolved_layout
    name = Current.theme&.template_name
    name = "default" unless TEMPLATES.include?(name)
    :"layouts/#{name}"
  end
end
```

```ruby
# in a route — pick the layout structure at render time
get "/notes" do
  notes = Current.account.notes_dataset.all   # data resolved in the route, not the view
  erb :"notes/index", layout: resolved_layout, locals: { notes: notes }
end
```

```
views/layouts/
├── default.erb
├── minimal.erb
└── bold.erb        # each is layout structure only; all use the same tokens
```

### Template rules **[core]**

- Every variant implements the same required blocks. Unknown/missing name → the allowlist guard falls back to `default`.
- Templates control structure and layout only. **No business logic** — no Sequel queries, no Faraday/API calls, no `Current`/policy checks, no auth/subscription conditionals. That lives in the route/service; the template renders passed-in locals.
- All variants consume the same CSS custom properties for color and typography.

```erb
<%# ❌ business logic in a layout/template — Sequel query + Current in the view %>
<% if Current.user && Current.account.notes_dataset.any? %> … <% end %>

<%# ✅ route computed it; template just renders the passed-in local %>
<% if show_notes %> … <% end %>
```

---

## Absolute Rules — Never Violate **[core]**

- Never hardcode brand colors/fonts/radii in templates — read CSS variables.
- Never store binary asset data in SQLite — store object-store URLs (Litestream replicates the DB file; blobs slow every write).
- Never put business logic (Sequel queries, `Current`/policy checks, Faraday calls) in a layout/template variant.
- Never inject un-validated theme values into the inline `<style>` block — validate/whitelist color and URL fields on write. Sinatra's ERB does not auto-escape, and inside `<style>` escaping is not a sufficient defense; validation on write is.
- Ship one CSS file (`public/css/app.css`); per-tenant change is the `:root` variable block only.
