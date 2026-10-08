# Rails theming

CSS custom properties are the shared customization boundary. Define a static
single-brand token layer first; Rails layouts and partials consume it. The starter
does not create theme tables, tenant settings or an asset build service.

For a requirement involving multiple brands, keep component structure in shared
partials and change token values. Resolve the selected theme at the request/domain
boundary and pass presentation values to the layout. Do not query Active Record,
check policies or call external services from a view.

If theme values become user-configurable, validate every field against a narrow
allowlist before storing or rendering it. Colors, font names, dimensions, layout
names and asset URLs need their own constraints. HTML escaping alone is not a
CSS validation strategy and cannot make arbitrary content safe inside a style
block. Never mark untrusted values HTML-safe. Prefer enumerated choices over raw
CSS input; account for the application's Content Security Policy.

Select layout variants from an explicit allowlist. Unknown variants fall back to
the documented default. All variants must retain the same accessibility and
semantic-token contracts. Test allowed choices, fallback, invalid input and
cross-scope access if tenant configuration is introduced.

Do not store uploaded image bytes in the replicated SQLite database. If uploads
are needed, introduce explicit storage, authorization and backup requirements;
that capability is not provided by a logo URL or theme convention.
