# Rails frontend map

Keep this map aligned with the generated application as it changes. It describes
ownership boundaries rather than a requirement to add more layers.

| Area | Responsibility |
| --- | --- |
| `config/routes.rb` | HTTP routes and health endpoints |
| `app/controllers/` | Strong parameters, domain calls, response status and rendering |
| `app/services/notes/` | Create, paginated list and archive operations; explicit outcomes |
| `app/models/` | Active Record persistence, validations and record invariants |
| `app/views/` | Escaped server-rendered ERB; presentation from assigned values/locals |
| Shared stylesheet | Semantic CSS tokens, layout and visible interaction states |
| `spec/requests/` | HTTP success, validation, rendering and health contracts |
| `features/` | Executable Gherkin acceptance flows through Capybara RackTest |

The starter deliberately has no JavaScript-dependent interaction. If progressive
enhancement is added, document its entry point, DOM contract, cleanup behavior
and real-browser tests here. Keep business rules in the same services used by
controllers; a browser must not become a second implementation of the domain.

For a new screen, update the route, controller/service boundary, partials, empty
and error states, accessibility behavior and corresponding tests together. Use
`data-testid` for stable selectors. Document any external asset or browser build
step before relying on it in deployment.
