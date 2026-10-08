# Separation of concerns

Use Rails conventions without putting the entire application in controllers or
callbacks. Domain service modules are the Rails equivalent of context functions.

| Layer | Responsibility | Avoid |
| --- | --- | --- |
| Routes | Map verbs and paths to actions | Business rules |
| Controllers | Strong parameters, service calls, HTTP result handling | Raw SQL and mutation orchestration |
| Domain services | Transactions, expected Result tags, audit and event timing | Rendering and request globals |
| Models | Persistence constraints, associations, named scopes | Network requests in callbacks |
| ERB and partials | Escaped display of explicit locals | Queries, authorization, hidden mutable state |
| Optional clients | Vendor-specific protocol and error translation | SDK calls spread across the app |

Keep public methods small and named for domain intent. Reuse a helper when it
represents a coherent operation, not to hide complexity from lint. Zeitwerk
paths must match constants. Avoid generic service frameworks and broad concerns
until repeated behavior justifies them.

Use `Success(value)` and `Failure([:tag, details])` consistently. Validation errors
come from the model; unexpected failures raise. Controllers use 422 for rejected
input, 404 for missing content and 303 after a successful form mutation.

Prefer explicit arguments for tenant/actor scope. `ActiveSupport::CurrentAttributes`
may hold correlation data after a real need emerges; Rails resets it at request
boundaries, but jobs must establish their own context. It is not authorization.
Do not copy Sinatra thread-local reset code into Rails.

Keep transactions short. Write durable audit data atomically. Schedule optional
observations only after all open transactions commit. See
`architecture-decisions.md` for the distinction between callbacks and an outbox.
