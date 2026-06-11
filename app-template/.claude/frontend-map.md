# Frontend Map

> Template — fill in with your app's actual routes, LiveViews, components, JS hooks, and layout hierarchy. Replace every `<placeholder>`.

Quick-reference for navigating your Phoenix app's frontend layer. Covers routes, LiveViews,
components, JS hooks, and layout hierarchy. Keep this file current — it is the first stop
for any developer orienting to the UI.

---

## Layout Hierarchy

Document the nesting of your root template, layout components, and the LiveViews or
static templates rendered inside each. A typical Phoenix app has one root template and
several layout shells differentiated by audience (public, authenticated, admin, etc.).

```
root.html.heex                         ← HTML skeleton, meta tags, asset loading
├── <PublicLayout>.<public_layout>     ← Public-facing shell: header, nav, footer
│   └── Public LiveViews               ← e.g. HomeLive, PostShowLive, SearchLive
├── <AdminLayout>.<admin_layout>       ← Authenticated admin shell: sidebar + main
│   └── Admin LiveViews                ← e.g. DashboardLive, PostsLive, UsersLive
└── Layouts.app                        ← Minimal layout for auth flows
    └── UserLive views                 ← Login, Registration, Settings, Confirmation
```

Replace `<PublicLayout>`, `<AdminLayout>`, etc. with your actual module names. Add or
remove layout branches to match your app's audience splits.

---

## Route → LiveView Map

List every significant route. Group by audience or section. Note auth requirements and
any special behavior. Keep the "Notes" column brief — one phrase per route.

### Public Routes

Routes accessible to unauthenticated visitors, or with optional auth.

| Route                        | LiveView                          | Auth     | Notes |
|------------------------------|-----------------------------------|----------|-------|
| `/`                          | `<Public.HomeLive>`               | None     | Marketing or app landing page |
| `/<resources>`               | `<Public.ResourceIndexLive>`      | None     | Browse/search resources |
| `/<resources>/:id`           | `<Public.ResourceShowLive>`       | None     | Single resource detail |
| `/register`                  | `<UserLive.Registration>`         | None     | New user signup |
| `/log-in`                    | `<UserLive.Login>`                | None     | Login form |

_Example row (delete when filled):_
| `/posts`                     | `MyAppWeb.Public.PostsLive`       | None     | Paginated public post list |

### Authenticated User Routes

Routes that require a logged-in user.

| Route                        | LiveView                          | Notes |
|------------------------------|-----------------------------------|-------|
| `/account`                   | `<UserLive.Settings>`             | Profile, email, password |
| `/<resources>/new`           | `<Resource.NewLive>`              | Create a new resource |
| `/<resources>/:id/edit`      | `<Resource.EditLive>`             | Edit owned resource |

_Example row (delete when filled):_
| `/posts/new`                 | `MyAppWeb.Posts.NewLive`          | Create a post, author-only |

### Admin Dashboard (`/admin/*` — requires admin role)

| Route                        | LiveView                          | Notes |
|------------------------------|-----------------------------------|-------|
| `/admin`                     | `<Admin.DashboardLive>`           | Platform overview, KPIs |
| `/admin/<resources>`         | `<Admin.ResourceIndexLive>`       | List + manage all resources |
| `/admin/<resources>/new`     | `<Admin.ResourceNewLive>`         | Admin create resource |
| `/admin/<resources>/:id`     | `<Admin.ResourceShowLive>`        | Admin resource detail |
| `/admin/<resources>/:id/edit`| `<Admin.ResourceEditLive>`        | Admin edit resource |
| `/admin/users`               | `<Admin.UsersLive>`               | All user management |
| `/admin/settings`            | `<Admin.SettingsLive>`            | App-wide configuration |

_Example row (delete when filled):_
| `/admin/posts`               | `MyAppWeb.Admin.PostsLive`        | Manage all posts across users |

### Super Admin (`/super/*` — requires super admin flag)

Add this section only if your app has a platform-level layer above the standard admin.
Remove the section entirely if not applicable.

| Route                        | LiveView                          | Notes |
|------------------------------|-----------------------------------|-------|
| `/super`                     | `<Super.DashboardLive>`           | Platform-level overview |
| `/super/<resources>`         | `<Super.ResourceIndexLive>`       | Cross-tenant resource list |
| `/super/users`               | `<Super.UsersLive>`               | All users across tenants |

### Auth Routes

| Route                        | LiveView / Controller             | Notes |
|------------------------------|-----------------------------------|-------|
| `/users/register`            | `<UserLive.Registration>`         | New user signup |
| `/users/log-in`              | `<UserLive.Login>`                | Login form |
| `/users/log-in/:token`       | `<UserLive.Confirmation>`         | Email confirmation |
| `/users/settings`            | `<UserLive.Settings>`             | Logged-in user profile |

### API / Controller-Only Routes

| Route                        | Controller                        | Notes |
|------------------------------|-----------------------------------|-------|
| `/webhooks/<service>`        | `<WebhookController>`             | Inbound webhook receiver |
| `/health`                    | `<HealthController>`              | Health check endpoint |
| `/api/<resources>`           | `<Api.ResourceController>`        | JSON API, if applicable |

_Example row (delete when filled):_
| `/webhooks/stripe`           | `MyAppWeb.WebhookController`      | Stripe event receiver |

---

## Component Modules

List the component modules your templates and LiveViews pull from. Note where each
lives, and what category of UI it provides.

| Module                            | File                                      | Purpose |
|-----------------------------------|-------------------------------------------|---------|
| `MyAppWeb.CoreComponents`         | `components/core_components.ex`           | Phoenix-generated: tables, forms, inputs, modals, flash, icons |
| `MyAppWeb.Layouts`                | `components/layouts.ex`                   | Root layout, app layout, flash group |
| `<MyAppWeb.PublicComponents>`     | `components/<public_components>.ex`       | Public UI: cards, hero, nav, footer |
| `<MyAppWeb.AdminComponents>`      | `components/<admin_components>.ex`        | Admin UI: sidebar, data tables, stat cards |
| `<MyAppWeb.PublicLayout>`         | `components/<public_layout>.ex`           | Public shell: header, nav, mobile menu |
| `<MyAppWeb.AdminLayout>`          | `components/<admin_layout>.ex`            | Admin shell: sidebar nav, top bar |

_Example row (delete when filled):_
| `MyAppWeb.Components.PostCard`    | `components/post_card.ex`                 | Reusable post preview card used in index and search views |

---

## JS Hooks → LiveView Usage

List every JavaScript hook registered in `app.js`. Document which LiveView mounts it,
what DOM events it handles, and which server events it pushes or receives.

| Hook                  | File                             | Used By                          | Server Events |
|-----------------------|----------------------------------|----------------------------------|---------------|
| `<HookName>`          | `hooks/<hook_name>.ts`           | `<LiveView>`                     | `<event_name>` |

_Example rows (delete when filled):_
| `InfiniteScroll`      | `hooks/infinite_scroll.ts`       | `MyAppWeb.Posts.IndexLive`       | Pushes `load_more` |
| `RichTextEditor`      | `hooks/rich_text_editor.ts`      | `MyAppWeb.Posts.NewLive`         | Receives `insert_image_url` |
| `Sortable`            | `hooks/sortable.ts`              | `MyAppWeb.Admin.ResourcesLive`   | Pushes `reordered` |

For each hook, document:
- Which LiveView or component renders the element with `phx-hook`
- Events the hook **pushes** to the server via `this.pushEvent`
- Events the hook **handles** from the server via `this.handleEvent`

---

## Shared LiveView Behavior (Macros / `__using__`)

If your app defines `__using__` macros that inject shared `on_mount`, `handle_event`,
or `handle_info` clauses into multiple LiveViews, document them here.

| Module                        | File                              | Injected Into              | Provides |
|-------------------------------|-----------------------------------|----------------------------|----------|
| `<MyAppWeb.SharedBehavior>`   | `live/<shared_behavior>.ex`       | `<ListOfLiveViews>`        | e.g. shared pagination, filter state, current user assigns |

_Example row (delete when filled):_
| `MyAppWeb.Live.PaginationHooks` | `live/pagination_hooks.ex`      | PostsLive, UsersLive       | `handle_event "paginate"`, assigns `page`, `per_page`, `total_pages` |

---

## CSS Architecture

Describe your styling approach so contributors know where styles live and how to extend
them without introducing inconsistency.

- **Framework** — e.g. Tailwind CSS, daisyUI, plain CSS. Where utility classes are used
  and where component classes are preferred.
- **Custom properties** — if your app injects CSS custom properties (e.g. for theming),
  document the prefix, where they are set, and what controls them.
- **File locations** — `assets/css/app.css` for global styles; component-specific styles
  (if any) colocated with component files or in dedicated CSS files.
- **Conventions** — e.g. no hardcoded color values in templates, all colors via variables.

_Example (delete when filled):_
- Tailwind CSS utility-first; daisyUI component classes for admin UI.
- `--app-*` custom properties for public theming, injected on `.app-root`.
- `assets/css/app.css` imports Tailwind base, component, and utility layers.
- No hardcoded hex values in templates — always reference a CSS variable or Tailwind token.

---

## Pipelines (Authentication / Authorization)

Document your router pipelines and any LiveView `on_mount` hooks that enforce auth.

### Router Pipelines

| Pipeline                    | Purpose |
|-----------------------------|---------|
| `:browser`                  | Standard browser stack (session, CSRF, flash) |
| `:<require_auth>`           | Redirects to login if user not authenticated |
| `:<require_admin>`          | Requires admin role; 403 or redirect otherwise |
| `:<require_super_admin>`    | Requires super admin flag |
| `:<optional_auth>`          | Loads current user if session exists, does not require it |

_Example rows (delete when filled):_
| `:browser`                  | Standard Phoenix browser pipeline |
| `:require_authenticated`    | Redirects unauthenticated users to `/log-in` |
| `:require_admin`            | Checks `user.role == :admin`; redirects otherwise |

### LiveView `on_mount` Hooks

| Hook                                     | Purpose |
|------------------------------------------|---------|
| `<MyAppWeb.UserAuth> :require_authenticated` | User must be logged in; redirects to login if not |
| `<MyAppWeb.UserAuth> :mount_current_user`    | Loads current user into assigns if session exists; does not redirect |
| `<MyAppWeb.AdminAuth> :require_admin`        | Admin role required for LiveView mount |

---

## Where to Find Things

Use this section as a quick orientation index. Update paths to match your actual
project structure.

| What you are looking for              | Where to look |
|---------------------------------------|---------------|
| Route definitions                     | `lib/<my_app>_web/router.ex` |
| LiveView modules                      | `lib/<my_app>_web/live/` |
| Function component modules            | `lib/<my_app>_web/components/` |
| Root and app layout templates         | `lib/<my_app>_web/components/layouts/` |
| JavaScript hooks                      | `assets/js/hooks/` |
| Hook registration                     | `assets/js/app.js` (the `Hooks` object) |
| Global CSS                            | `assets/css/app.css` |
| Static assets                         | `priv/static/` |
| Context modules (business logic)      | `lib/<my_app>/` |
| Tests for LiveViews                   | `test/<my_app>_web/live/` |
| Tests for components                  | `test/<my_app>_web/components/` |
