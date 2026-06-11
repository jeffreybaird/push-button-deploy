# TypeScript Hooks

Load this file when working on LiveView hooks, third-party JS library integrations,
push notifications, or any client-side JavaScript.

> **Baseline:** Phoenix 1.8 · LiveView 1.1. Colocated hooks (LV 1.1) are idiomatic for small component-scoped hooks; the global-registration pattern remains valid for larger/shared hooks — both coexist.

---

## Build System

Phoenix ships with esbuild, which handles TypeScript natively — no webpack, no
babel, no additional config. Files are named `.ts` and esbuild strips types and
bundles them.

A `tsconfig.json` exists in `assets/` for editor support and CI type checking.
esbuild does **not** type-check — `tsc --noEmit` runs as a separate CI step.

---

## File Structure

```
assets/
├── js/
│   ├── app.ts                      # Entry point — imports and registers hooks
│   ├── hooks/
│   │   ├── index.ts                # Re-exports all hooks as a single object
│   │   ├── clipboard_copy.ts      # Copies text to clipboard on click
│   │   ├── infinite_scroll.ts     # Loads more items when user reaches bottom
│   │   ├── push_notifications.ts  # Web Push API registration
│   │   └── sortable.ts            # Drag-and-drop reordering
│   └── types/
│       ├── phoenix.d.ts           # Type defs for LiveView hook lifecycle
│       └── vendor.d.ts            # Type defs for third-party elements/libs
├── css/
│   └── app.css
└── tsconfig.json
```

### `app.ts` entry point

```typescript
import { hooks } from "./hooks"

const liveSocket = new LiveSocket("/live", Socket, {
  hooks,
  params: { _csrf_token: csrfToken },
})

liveSocket.connect()
```

### `hooks/index.ts`

```typescript
import ClipboardCopy from "./clipboard_copy"
import InfiniteScroll from "./infinite_scroll"
import PushNotifications from "./push_notifications"
import Sortable from "./sortable"

export const hooks = {
  ClipboardCopy,
  InfiniteScroll,
  PushNotifications,
  Sortable,
}
```

This dedicated-file + global-registration pattern is the right home for any hook that is
large, shared across multiple components, or wraps a heavy third-party library. Keep all of
the guidance in this section as-is for those cases. For small, single-component hooks, see
**Colocated Hooks** below.

---

## Colocated Hooks (LiveView 1.1)

LiveView 1.1 (released 2025-07-30, the LiveView release that pairs with Phoenix 1.8) adds
[colocated hooks](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.ColocatedHook.html):
you declare a hook inline in the same HEEx template/component that uses it, instead of in a
dedicated file registered globally. Requires `phoenix_live_view ~> 1.1`
([LV 1.1 release notes](https://www.phoenixframework.org/blog/phoenix-liveview-1-1-released)).

```heex
<div id={"copy-#{@id}"} phx-hook=".ClipboardCopy" data-copy-text={@text}>
  <button type="button">Copy</button>
  <script :type={Phoenix.LiveView.ColocatedHook} name=".ClipboardCopy">
    export default {
      mounted() {
        this.el.querySelector("button").addEventListener("click", () => {
          navigator.clipboard.writeText(this.el.dataset.copyText ?? "")
          this.pushEvent("copy_success", {})
        })
      }
    }
  </script>
</div>
```

A leading-dot name (`name=".ClipboardCopy"`, `phx-hook=".ClipboardCopy"`) is automatically
prefixed by the enclosing module, so two components can each define a `.ClipboardCopy`
without colliding
([ColocatedHook docs](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.ColocatedHook.html)).

The JS is **extracted at compile time** into `_build` and surfaced through the
`phoenix-colocated/<my_app>` manifest. You import that manifest and spread it into the
`LiveSocket` `hooks` option alongside your global hooks
([js-interop](https://hexdocs.pm/phoenix_live_view/js-interop.html)):

```typescript
import { hooks } from "./hooks"
import { hooks as colocatedHooks } from "phoenix-colocated/my_app"

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: { ...hooks, ...colocatedHooks },
  params: { _csrf_token: csrfToken },
})
```

New Phoenix 1.8 apps ship the esbuild config that resolves the `phoenix-colocated/<my_app>`
manifest out of the box
([ColocatedHook docs](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.ColocatedHook.html)).

### When to colocate vs. dedicated file

Colocated hooks are **complementary**, not a replacement — both styles coexist in the same
app.

| Situation                                              | Use                                              |
|--------------------------------------------------------|--------------------------------------------------|
| Small (under ~50 lines), used by one component         | ✅ Colocated hook (`<script :type={...}>`)        |
| Larger hook, or shared across multiple components      | ✅ Dedicated file `assets/js/hooks/*.ts` + global |
| Wraps a heavy third-party library                      | ✅ Dedicated file (keeps HEEx readable, reusable) |
| Needs its own JSDoc contract + CI type-checking in `tsc` | ✅ Dedicated file                                |

```
Is the hook small AND used by exactly one component?
├─ yes → colocate it inline (.HookName)
└─ no  → dedicated file in assets/js/hooks/*.ts + register in hooks/index.ts
```

All the rules below (thin bridges, `pushEvent`/`handleEvent` only, cleanup in `destroyed()`,
no global state) apply equally to colocated and dedicated-file hooks.

### CSP and the `runtime` variant

By default, colocated hooks are **extracted at compile time** and produce **no inline
`<script>` in the rendered page**, so they have **zero CSP impact** — a nonce-based
`script-src` policy needs no special handling
([ColocatedHook docs](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.ColocatedHook.html)).

The nonce concern applies **only** to the opt-in `runtime` variant
(`<script :type={Phoenix.LiveView.ColocatedHook} name=".MyHook" runtime ...>`), which keeps
the script inline at runtime. Under a nonce-based `script-src` CSP, that runtime script must
carry a `nonce` matching the CSP header:

```heex
<script :type={Phoenix.LiveView.ColocatedHook} name=".MyHook" runtime nonce={@script_csp_nonce}>
  export default { mounted() { /* ... */ } }
</script>
```

`nonce` is an ordinary HEEx attribute — nothing special is required to pass it through.

---

## Hook Interface

Every hook must conform to the Phoenix LiveView hook lifecycle:

```typescript
interface PhoenixHook {
  mounted(): void
  beforeUpdate?(): void
  updated?(): void
  destroyed?(): void
  disconnected?(): void
  reconnected?(): void

  // Provided by LiveView at runtime
  el: HTMLElement
  pushEvent(event: string, payload: object): void
  pushEventTo(selector: string, event: string, payload: object): void
  handleEvent(event: string, callback: (payload: object) => void): void
}
```

### Typed events (optional)

`pushEvent`/`handleEvent` payloads
([LiveView client API](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html)) are
`object` by default, so a typo in a payload field is invisible until runtime. For hooks with
a non-trivial event contract, map each event name to its payload and key the helper by event
name — the event/payload pair is then correlated, so a mismatch fails at `tsc` time:

```typescript
// Events this hook SENDS to the server: name → payload
type Outgoing = {
  copy_success: { text: string }
  playback_paused: { item_id: string; position: number }
}

// Events this hook RECEIVES from the server: name → payload
type Incoming = {
  reset_button: Record<string, never>
  seek_to: { position: number }
}

function push<K extends keyof Outgoing>(hook: PhoenixHook, event: K, payload: Outgoing[K]) {
  hook.pushEvent(event, payload)
}

function on<K extends keyof Incoming>(hook: PhoenixHook, event: K, cb: (p: Incoming[K]) => void) {
  hook.handleEvent(event, cb as (p: object) => void)
}

// ✅ ok
push(hook, "copy_success", { text: "hi" })
// ❌ tsc error — wrong payload shape for "copy_success"
push(hook, "copy_success", { item_id: "x", position: 0 })
```

Because the type parameter is bound to a single key (`K extends keyof Outgoing`), TS infers
the exact event and demands the matching payload — a union-bounded helper would widen and
silently accept any payload. This is optional and lives alongside the JSDoc contract
(rule 3), not instead of it.

### Hook template

```typescript
/**
 * ClipboardCopy hook
 *
 * Copies the value of data-copy-text to the clipboard when the element
 * is clicked, then notifies the server so the UI can show confirmation.
 *
 * Events sent to server:
 *   - "copy_success" { text }
 *
 * Events received from server:
 *   - "reset_button" {}
 *
 * Dataset attributes read:
 *   - data-copy-text: the string to copy to clipboard
 */
const ClipboardCopy = {
  mounted() {
    this.handleClick = () => {
      const text = this.el.dataset.copyText ?? ""
      navigator.clipboard.writeText(text).then(() => {
        this.pushEvent("copy_success", { text })
      })
    }
    this.el.addEventListener("click", this.handleClick)

    this.handleEvent("reset_button", () => {
      // server signals button can return to idle state
    })
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
  },
}

export default ClipboardCopy
```

---

## Keyed comprehensions (`:key`) — when rendering dynamic lists

Cross-ref for the HEEx side of a hook-driven list. For a plain `:for` over a **dynamic
in-memory collection** (not a stream), add `:key={item.id}` so LiveView diffs by identity.
LiveView 1.1 defaults to index-based change tracking, which marks every subsequent item as
changed when you prepend or reorder; `:key` makes the diff follow the item instead
([LV 1.1 release notes](https://www.phoenixframework.org/blog/phoenix-liveview-1-1-released),
[changelog](https://hexdocs.pm/phoenix_live_view/changelog.html)).

```heex
<%!-- ✅ dynamic in-memory list: diff by identity --%>
<div :for={item <- @items} :key={item.id} id={"item-#{item.id}"} phx-hook="Sortable">…</div>

<%!-- ❌ stream: :key has no effect — streams track by DOM id already --%>
<div :for={{dom_id, item} <- @streams.items} id={dom_id}>…</div>
```

`:key` has **no effect inside a stream** — streams already track items by DOM id. This
matters for hook stability: without identity-based diffing, a reorder can tear down and
re-mount the wrong hooks.

---

## Rules

### 1. Hooks are thin bridges — no business logic

Hooks manage DOM interactions and JS library bindings. They do not make decisions
about what to show, how to filter data, or what permissions the user has. That
logic lives server-side in the LiveView.

```typescript
// ✅ CORRECT — hook reports an event, server decides what to do
this.pushEvent("item_reached_end", { page: this.currentPage })

// ❌ WRONG — hook decides to filter or transform data
fetch("/api/items?filter=active", { method: "GET" }).then(...)
```

### 2. Communicate via `pushEvent` / `handleEvent`

Hooks communicate with the server exclusively through the LiveView socket.
Never make direct HTTP calls (fetch, XMLHttpRequest) from hooks. The only
exception is uploads that go directly to a third-party service (e.g. a media
provider's direct-upload endpoint) rather than your own server.

### 3. All hooks must have JSDoc comments

Every hook must document:
- What it does (one sentence)
- Events it **sends** to the server (name + payload shape)
- Events it **receives** from the server (name + payload shape)
- Any DOM attributes it reads from `this.el.dataset`

### 4. Clean up in `destroyed()`

If a hook adds event listeners, timers, or creates objects (e.g. a third-party
widget instance), it must clean them up in `destroyed()` to prevent memory leaks
during LiveView navigation.

### 5. No global state

Hooks must not store state in module-level variables or on `window`. All state
lives on `this` (the hook instance) so it's scoped to the element's lifecycle.

```typescript
// ✅ CORRECT — state on the hook instance
mounted() {
  this.observer = new IntersectionObserver(this.onIntersect.bind(this))
  this.intervalId = setInterval(() => this.ping(), 30000)
}

// ❌ WRONG — global state
let observer: IntersectionObserver
let intervalId: number
```

---

## Third-Party JS Library Integration

When wrapping a third-party library (e.g. a media player, a chart renderer, a
rich-text editor), the pattern is the same regardless of vendor:

1. Load the library via CDN in the layout `<head>`, or import it as an npm
   dependency in `assets/package.json`.
2. Render the host element from HEEx with a `phx-hook` attribute and any
   configuration via `data-*` attributes.
3. In `mounted()`, instantiate the library, read config from `this.el.dataset`,
   and bind its events to `pushEvent` calls.
4. In `destroyed()`, destroy the instance and remove listeners.

Example — a generic embedded player web component:

```heex
<div id={"player-#{@item.id}"}
     phx-hook="MediaPlayer"
     data-playback-id={@item.playback_id}
     data-item-id={@item.id}>
  <vendor-player
    playback-id={@item.playback_id}
    metadata-title={@item.title}
    stream-type="on-demand"
  />
</div>
```

```typescript
/**
 * MediaPlayer hook
 *
 * Mounts a third-party player web component and bridges playback events
 * to the LiveView server.
 *
 * Events sent to server:
 *   - "playback_started" { item_id, timestamp }
 *   - "playback_paused"  { item_id, position }
 *   - "playback_ended"   { item_id }
 *
 * Events received from server:
 *   - "seek_to" { position }
 *
 * Dataset attributes read:
 *   - data-item-id
 *   - data-playback-id
 */
const MediaPlayer = {
  mounted() {
    const player = this.el.querySelector("vendor-player")
    const itemId = this.el.dataset.itemId

    player.addEventListener("play",  () => this.pushEvent("playback_started", { item_id: itemId, timestamp: Date.now() }))
    player.addEventListener("pause", () => this.pushEvent("playback_paused",  { item_id: itemId, position: player.currentTime }))
    player.addEventListener("ended", () => this.pushEvent("playback_ended",   { item_id: itemId }))

    this.handleEvent("seek_to", ({ position }) => { player.currentTime = position })

    this.player = player
  },

  destroyed() {
    // vendor-player cleans itself up when removed from the DOM;
    // remove any listeners you added manually here
  },
}

export default MediaPlayer
```

---

## tsconfig.json

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "baseUrl": ".",
    "paths": {
      "@hooks/*": ["js/hooks/*"],
      "@types/*": ["js/types/*"]
    }
  },
  "include": ["js/**/*.ts"],
  "exclude": ["node_modules"]
}
```

This file drives editor tooling and the `tsc --noEmit` CI step (see **Build System** above);
esbuild ignores it when **bundling**. The two tools read different fields:

| Setting                          | esbuild (bundle)        | `tsc` (type check)        |
|----------------------------------|-------------------------|---------------------------|
| `target`, `module`               | ❌ ignored — esbuild picks its own output target/format ([esbuild TS](https://esbuild.github.io/content-types/typescript/)) | ✅ used |
| `strict`                         | ❌ ignored — esbuild never type-checks | ✅ used |
| `paths` / `baseUrl` (aliases)    | ❌ ignored — alias resolution is configured in the esbuild build, not here | ✅ used ([tsconfig](https://www.typescriptlang.org/tsconfig)) |
| `moduleResolution`               | ❌ ignored | ✅ used |

`moduleResolution: "bundler"` is the right value here: it tells `tsc` to resolve imports the
way a bundler (esbuild) does, so the type checker and the build agree on what resolves
([tsconfig](https://www.typescriptlang.org/tsconfig)). Because esbuild transpiles each file
independently and never reads `tsconfig.json`, type errors only surface in the separate
`tsc --noEmit` step — never at bundle time.

---

## Related docs

- `separation-of-concerns.md` — where hook logic ends and LiveView logic begins
- `external-service-integration.md` — patterns for third-party API/SDK integration
- `theming.md` — passing theme values from server to hook via `data-*` attributes
- `design-system.md` — component conventions that hooks may need to interact with
