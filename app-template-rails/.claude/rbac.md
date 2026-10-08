# Optional authentication and authorization

The fresh Notes sample is public and has no users, sessions for identity, roles
or authorization policies. This guide describes future work, not installed auth.

Resolve identity with a maintained Rails-compatible authentication approach when
required. Rotate sessions after sign-in, protect mutation forms with CSRF, use
secure cookies behind HTTPS and generic login/recovery errors that do not reveal
whether an email exists. Store credentials only through appropriate password
hashing or a trusted identity provider, never application logs.

Keep three questions separate: identity says who acts, scope says which rows
are visible, and a policy says which actions that actor may perform. A scoped
finder is not permission to mutate. Enforce policies in server-side operations
as well as request boundaries when other callers exist; hiding UI is insufficient.

If multi-tenant, store roles on memberships. Resolve membership against the
current tenant and never accept actor/tenant/role authority from form fields.
Cross-tenant administration needs a clearly named, separately authorized and
audited boundary, not an incidental `unscoped` query.

Use tagged `Failure([:forbidden])` for expected authorization failures. Return
not-found where disclosing another tenant's record would leak its existence.
Test allowed and denied actions, cross-tenant IDs and direct service calls.
Do not generate speculative roles or install a policy gem before the domain
requires one. See `multi-tenancy.md` for explicit data boundaries.
