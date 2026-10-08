# My React App

A browser-only React and TypeScript application built with Vite. CI runs
`npm ci`, `npm test`, and `npm run build`, then publishes `dist/` through the
shared Caddy static release path. There is no application server or database.

Shared guidance and workflow hooks are managed by `agent-docs.sh`. Put local
rules in `.docs/project-guidance.md`; managed template edits block updates.

## Development

Use the Node version in `.node-version`. Run `npm ci` to install the committed
lock, `npm run dev` for development, `npm test` for component tests, and
`npm run build` for TypeScript checking and production output. Commit dependency
changes with `package-lock.json`; never commit `node_modules/` or `dist/`.

Start with `src/App.tsx`. Build accessible components, keep state ownership
explicit, and exercise user interactions in component tests. Use browser storage
only when the feature needs local persistence; it is per browser and is not a
shared database. Network integrations require a separately operated API.

## Deployment

GitHub and Gitea both publish static files and retain releases for rollback.
Caddy supports client-side route refreshes, returns 404 for missing assets,
and revalidates HTML so releases and rollbacks take effect on reload.

Keep Vite's default root base (`/`) and output directory (`dist`). This deployment
does not run SSR, API handlers, or a Node production process. Never put secrets
in browser code or `VITE_*` variables: all bundled values are public. Use an API
that handles its own authorization and CORS for server-side capabilities.

- `.docs/react.md` — component, testing, and build conventions.
