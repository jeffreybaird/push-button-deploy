# Frontend Map

> Template — fill in with your app's actual routes, services, ERB views, vanilla JS modules, and layouts. Replace every `<placeholder>` and the example rows.

> **Baseline:** Modular Sinatra (`class App < Sinatra::Base`) + Sequel + SQLite, served by Puma. ERB views in `views/`, optional small vanilla JS in `public/js/`. Keep this map current — it's how Claude navigates the UI.

Quick-reference for navigating `MyApp`'s frontend layer. It is the first stop for any
developer — or Claude — orienting to the UI. When routes, ERB views, vanilla JS modules, or
layouts change, update this file in the same commit.

---

## Stack

State the frontend stack this app uses so readers know which sections apply.

- **Framework:** Modular Sinatra — `class App < Sinatra::Base` in `app.rb`, booted by Puma via `config.ru` (`run App`)
- **Templating:** ERB in `views/`, wrapped by the default layout `views/layout.erb`
- **Front-end JS:** none by default — small vanilla ES modules in `public/js/`, loaded per page with `<script type="module">`. No Hotwire / Turbo / Stimulus / importmap (that's Rails)
- **CSS:** plain CSS / Sass in `public/css/` (note which). No Tailwind unless you add it
- **Static assets:** `public/` — served directly by Sinatra (`set :public_folder`); no asset pipeline by default

---

## Layout Hierarchy

Document the nesting of your layouts and which routes render inside each. A typical app has
one default layout plus alternate shells differentiated by audience (public, authenticated,
admin, auth).

Layouts live in `views/`. Sinatra wraps every `erb` render in `views/layout.erb` by default.
Select an alternate shell per render with `erb :"notes/index", layout: :"layouts/admin"`, or
pass `layout: false` for no shell.

```
views/layout.erb                      ← HTML skeleton, meta tags, <%= yield %>, <link>/<script> tags
├── views/layouts/public.erb          ← Public shell: header, nav, footer
│   └── Public routes                 ← e.g. GET /, GET /notes
├── views/layouts/admin.erb           ← Admin shell: sidebar + main
│   └── /admin/* routes               ← e.g. GET /admin, GET /admin/notes
└── views/layouts/auth.erb            ← Minimal shell for auth flows
    └── sign-in / sign-up / password routes
```

Replace these with your actual layout files. Add or remove branches to match your audience
splits. Note the Sinatra difference: there is no per-controller `layout` macro — each route
passes `layout:` explicitly (or you set a default via a helper/`before` filter on `App`).

---

## Route → Service → View Map

List every significant route defined as a Sinatra block. Group by audience. Note auth
requirements and special behavior. Keep the "Notes" column to one phrase per route.

> **Sinatra:** routes are thin blocks — `get "/notes" do … end` — on `class App < Sinatra::Base`
> in `app.rb`, or split into `app/routes/*.rb` and registered on `App`. There's no
> `bin/rails routes`; dump the table by grepping the route files:
> `grep -rnE '^\s*(get|post|put|patch|delete) ' app.rb app/routes`.

Routes hold **no** business logic and **no** raw SQL: they parse params, invoke a service
(`app/services/<domain>/<verb>.rb`, returning a dry-monads `Success`/`Failure`), then render
an ERB view. See `.claude/separation-of-concerns.md`.

### Public Routes

Accessible to unauthenticated visitors, or with optional auth.

| Path & verb            | Route → Service                       | View                        | Auth | Notes |
|------------------------|----------------------------------------|-----------------------------|------|-------|
| `GET /`                | `<none — static/landing>`              | `views/home/index.erb`      | None | Landing page |
| `GET /<resources>`     | `<Resources::List>`                    | `views/<resources>/index.erb` | None | Browse/search + pagination |
| `GET /<resources>/:id` | `<Resources::Show>`                    | `views/<resources>/show.erb`  | None | Single resource detail |
| `GET /sign_up`         | `<none — renders form>`                | `views/registrations/new.erb` | None | New user signup |
| `GET /sign_in`         | `<none — renders form>`                | `views/sessions/new.erb`      | None | Login form |

_Example row (delete when filled):_
| `GET /notes`           | `Notes::List`                          | `views/notes/index.erb`     | None | Paginated public note list |

### Authenticated User Routes

Require a logged-in user (`Current.user` present — see Authentication below).

| Path & verb                  | Route → Service                  | View                          | Notes |
|------------------------------|-----------------------------------|-------------------------------|-------|
| `GET /account`               | `<none — renders form>`           | `views/accounts/edit.erb`     | Profile, email, password |
| `GET /<resources>/new`       | `<none — renders form>`           | `views/<resources>/new.erb`   | Create form |
| `POST /<resources>`          | `<Resources::Create>`             | redirect or `…/new.erb` on `Failure` | Create resource |
| `GET /<resources>/:id/edit`  | `<Resources::Show>`               | `views/<resources>/edit.erb`  | Edit owned resource |
| `POST /<resources>/:id`      | `<Resources::Update>`             | redirect or `…/edit.erb` on `Failure` | Update owned resource (HTML forms POST; use a `_method` hidden field for PUT/PATCH/DELETE) |

_Example row (delete when filled):_
| `POST /notes`                | `Notes::Create`                   | redirect `/notes/:id` or `new.erb` | Author-only create; `authorize!(Note, :create)` |

### Admin Routes (`/admin/*` — requires admin role)

| Path & verb                       | Route → Service                  | View                            | Notes |
|-----------------------------------|-----------------------------------|---------------------------------|-------|
| `GET /admin`                      | `<Admin::Dashboard::Load>`        | `views/admin/dashboard.erb`     | Platform overview, KPIs |
| `GET /admin/<resources>`          | `<Admin::Resources::List>`        | `views/admin/<resources>/index.erb` | List + manage all |
| `GET /admin/<resources>/:id`      | `<Admin::Resources::Show>`        | `views/admin/<resources>/show.erb`  | Admin detail |
| `POST /admin/<resources>/:id`     | `<Admin::Resources::Update>`      | redirect or re-render           | Admin update |
| `GET /admin/users`                | `<Admin::Users::List>`            | `views/admin/users/index.erb`   | User management |
| `GET /admin/settings`             | `<none — renders form>`           | `views/admin/settings/edit.erb` | App-wide config |

_Example row (delete when filled):_
| `GET /admin/notes`                | `Admin::Notes::List`              | `views/admin/notes/index.erb`   | Manage all notes across users |

### Auth Routes

Session via `Rack::Session::Cookie` (`enable :sessions`); passwords hashed with `bcrypt`.
No Devise. HTML forms POST; sign-out uses a `_method=DELETE` hidden field (`Rack::MethodOverride`).

| Path & verb            | Route → Service                       | View                          | Notes |
|------------------------|----------------------------------------|-------------------------------|-------|
| `GET /sign_up`         | `<none — renders form>`                | `views/registrations/new.erb` | New user signup |
| `POST /sign_up`        | `<Registrations::Create>`             | redirect or `new.erb`         | Create account |
| `GET /sign_in`         | `<none — renders form>`                | `views/sessions/new.erb`      | Login form |
| `POST /sign_in`        | `<Sessions::Create>`                   | redirect or `new.erb`         | Create session |
| `POST /sign_out`       | `<Sessions::Destroy>`                  | redirect `/`                  | Log out (`_method=DELETE`) |
| `GET /password/reset`  | `<none — renders form>`                | `views/passwords/new.erb`     | Request reset |

### API / Non-HTML Routes

Sequel `plugin :json_serializer` renders JSON; there's no built-in health route, so define one.

| Path & verb              | Route → Service                    | Renders | Notes |
|--------------------------|-------------------------------------|---------|-------|
| `POST /webhooks/<svc>`   | `<Webhooks::Service::Handle>`       | `200`   | Inbound webhook receiver (verify signature in the service) |
| `GET /up`                | `<inline — get("/up"){ 200 }>`      | `200`   | Liveness probe (define it yourself; Sinatra has none) |
| `GET /api/<resources>`   | `<Resources::List>`                 | JSON    | `content_type :json` + `.to_json` (see `.claude/database.md` for `json_serializer`) |

_Example row (delete when filled):_
| `POST /webhooks/stripe`  | `Webhooks::Stripe::Handle`          | `200`   | Stripe event receiver |

---

## Views / Templates

List your view directories and notable templates/partials by area. Note the stable
`data-testid` anchor each view exposes so specs and JS can find it.

> **Sinatra:** templates live in `views/<area>/<action>.erb`; partials are `views/<area>/_name.erb`,
> rendered by calling `erb` again — e.g. `<%= erb :"notes/_card", locals: { note: note } %>`
> (define a thin `partial` helper on `App` if you want a shorthand). No ViewComponent.

| Area / view             | File                                    | `data-testid` anchor   | Purpose |
|-------------------------|-----------------------------------------|------------------------|---------|
| Default layout shell    | `views/layout.erb`                      | `app-root`             | HTML skeleton, `<%= yield %>`, asset tags |
| Public layout shell     | `views/layouts/public.erb`              | `public-shell`         | Header, nav, footer |
| Admin layout shell      | `views/layouts/admin.erb`               | `admin-shell`          | Sidebar, top bar |
| Shared flash            | `views/shared/_flash.erb`               | `flash`                | `aria-live` flash region (reads `session[:flash]`) |
| Resource list           | `views/<resources>/index.erb`           | `<resources>-list`     | Listing + pagination |
| Resource card partial   | `views/<resources>/_card.erb`           | `<resource>-card`      | Reused in index + search |
| Resource form partial   | `views/<resources>/_form.erb`           | `<resource>-form`      | Shared by new + edit |

_Example row (delete when filled):_
| Note card partial       | `views/notes/_card.erb`                 | `note-card`            | Reusable note preview, used in index + search |

---

## Vanilla JS Modules (`public/js/`)

Optional progressive enhancement only. The app renders full HTML pages server-side; JS is
plain ES modules served straight from `public/js/`, loaded per page with
`<script type="module" src="/js/<name>.js">`. Keep them thin — DOM glue, not business logic.
Modules locate elements by `data-testid` (or `data-*`) and, when they need server data, call a
JSON route (see the API section) rather than embedding logic.

| Module file                 | Loaded in (view)              | Hooks (`data-testid` / `data-*`) | Purpose |
|-----------------------------|-------------------------------|----------------------------------|---------|
| `public/js/<name>.js`       | `views/<area>/<action>.erb`   | `<hooks>`                         | `<what it does>` |

_Example rows (delete when filled):_
| `public/js/notes_filter.js` | `views/notes/index.erb`       | `notes-list`, `data-filter`      | Filters the visible note list client-side as you type |
| `public/js/dropdown.js`     | `views/layouts/admin.erb`     | `dropdown`, `dropdown-menu`      | Toggles a disclosure menu, manages `aria-expanded` |
| `public/js/clipboard.js`    | `views/notes/show.erb`        | `copy-source`, `copy-button`     | Copies text to clipboard, shows confirmation |

For each module, note the DOM events it binds and any `data-*` attributes it reads. There is
**no build step** by default — these are hand-written files. If you add a bundler (esbuild,
Vite), document the command and output path here.

---

## data-testid Hooks

Tests select by `data-testid`, **never** by CSS classes (see `.claude/testing.md`). Keep a
canonical list of stable hooks so ERB views, JS modules, and specs stay in agreement — renaming
one is a cross-cutting change. Any element a JS module rewrites, or any partial re-rendered
after a form POST, must keep its `data-testid` stable; if the update changes visible content it
MUST land in an `aria-live` region — see `.claude/a11y-audit.md`.

| `data-testid`           | Rendered in (view)            | Used by (spec / JS module)       | Purpose |
|-------------------------|-------------------------------|----------------------------------|---------|
| `<hook>`                | `<view>`                      | `<spec / module>`                | `<what it marks>` |

_Example rows (delete when filled):_
| `notes-list`            | `views/notes/index.erb`       | `spec/features/notes_spec.rb`, `notes_filter.js` | The `<ul>` wrapping note cards |
| `note-card`             | `views/notes/_card.erb`       | `spec/features/notes_spec.rb`    | A single note row |
| `flash`                 | `views/shared/_flash.erb`     | `spec/features/*`                | `aria-live` flash region |

Honest note on "partial updates": Sinatra renders full pages — there is no Turbo. A dynamic
update is either (a) a vanilla JS module fetching a JSON route and patching the DOM, or (b) a
normal form POST that re-renders the page/partial. Pick one per feature and document it above.

---

## CSS Architecture

Describe your styling approach so contributors know where styles live and how to extend them.

- **Framework** — plain CSS / Sass (note which). No Tailwind unless you add it; where utility vs. component classes are used.
- **Pipeline** — none by default: files are served straight from `public/css/`. If you add Sass, note the build command and output path.
- **Entry file** — `public/css/app.css`, linked from `views/layout.erb`.
- **Custom properties** — if you inject CSS custom properties for theming, document the prefix, where they're set, and what controls them. See `.claude/theming.md` and `.claude/design-system.md`.
- **Conventions** — no hardcoded color values in ERB; all colors via a CSS variable.

_Example (delete when filled):_
- Plain CSS, component classes for repeated admin UI; a small utility layer.
- Served from `public/css/app.css` — no build step.
- `--app-*` custom properties for theming, set on `.app-root`.
- No hardcoded hex values in templates — reference a CSS variable.

---

## Authentication / Authorization

Document how auth is enforced at the request layer.

> **Sinatra:** enforced with `before` filters and helper methods on `class App < Sinatra::Base`
> (not Rails `before_action`). `Current.user` is loaded from `Rack::Session::Cookie` in a
> `before` filter and cleared in an `after` filter — `Current` is the **data** boundary, not
> authorization (see `.claude/multi-tenancy.md`). Authorization is plain-Ruby policy objects in
> `app/policies/`, invoked through an `authorize!` helper — no Pundit. See `.claude/rbac.md`.

| Filter / helper                      | Applied to                   | Purpose |
|--------------------------------------|------------------------------|---------|
| `<set_current_user>` (before filter) | all routes                   | Loads `Current.user` from `session[:user_id]` if present |
| `<require_login!>`                   | authenticated routes         | `halt`/redirect to `/sign_in` if no `Current.user` |
| `<require_admin!>`                   | `/admin/*` routes            | 403 / redirect unless `Current.user.admin?` |

_Example rows (delete when filled):_
| `before { set_current_user }`        | `App` (all routes)           | Sets `Current.user`; resets in an `after` filter |
| `before("/admin/*") { require_admin! }` | `/admin/*`                | Checks `Current.user&.admin?`; redirects otherwise |

---

## Where to Find Things

Quick orientation index. Update paths to match your actual project structure.

| What you are looking for         | Where to look |
|----------------------------------|---------------|
| Route definitions                | `app.rb`, `app/routes/*.rb` (`grep -rnE '^\s*(get\|post\|put\|patch\|delete) '`) |
| Business logic (services)        | `app/services/<domain>/<verb>.rb` (dry-monads `Success`/`Failure`) |
| Models                           | `app/models/` (`Sequel::Model` subclasses) |
| Views / templates                | `views/` |
| Layouts                          | `views/layout.erb`, `views/layouts/` |
| Partials                         | `views/<area>/_*.erb` |
| Vanilla JS modules               | `public/js/` |
| Global CSS                       | `public/css/app.css` |
| Static assets                    | `public/` |
| Policies (authorization)         | `app/policies/<x>_policy.rb` |
| HTTP clients (3rd-party)         | `app/clients/` (Faraday) |
| DB config & migrations           | `config/database.rb`, `db/migrate/NNN_*.rb` — see `.claude/database.md` |
| Tests                            | `spec/` (request specs via Rack::Test, feature specs via Capybara + Rack::Test driver) |
