# Rails design system

Use accessible, server-rendered ERB as the default. The Notes starter demonstrates
semantic forms, clear success and error states, and CSS custom properties. Its
appearance is a starting point; document the application's actual visual language
here when its requirements are known.

## Tokens and components

Define brand colors, typography, radii and spacing as named CSS custom properties
in the shared stylesheet. Components consume semantic tokens such as surface,
text, accent and focus rather than repeating color literals. Keep layout rules
separate from theme values. Prefer a small vocabulary with documented purposes
over a new token for every element.

Use Rails partials for repeated markup and pass their inputs as locals. Resolve
queries, authorization and business decisions before rendering. A partial formats
provided data; it does not fetch records or invoke a domain service. Use Rails
form helpers for labels and inputs, `button_to` or a form for state changes, and
`link_to` for navigation. Rails escapes ordinary ERB output: do not use `raw` or
`html_safe` with user content.

## Interaction and content

Buttons describe the action: “Create note” and “Archive note”, not “Submit”. Empty
states explain what happened and provide an appropriate next action. Validation
retains entered values and associates specific, non-sensitive errors with their
fields. Authentication failures must not reveal whether an account exists.

Provide a visible focus style, meaningful headings, a skip link, and semantic
landmarks. Use at least 44 by 44 CSS pixel targets as the project's stronger
interaction default. Respect `prefers-reduced-motion`. See `a11y-audit.md` for
contrast, labels and keyboard verification.

Keep JavaScript limited to progressive enhancement. Do not put domain rules or
permissions in the browser. No JavaScript framework, asset build service or UI
component library is implied by these conventions; introduce one only for a
concrete requirement and add the corresponding build and browser tests.

Use `data-testid` for stable test selectors. Do not couple acceptance tests to
CSS classes, colors or incidental nesting. Server-rendered flows run through
Capybara's RackTest driver; add a real browser only when JavaScript behavior
needs to be exercised.
