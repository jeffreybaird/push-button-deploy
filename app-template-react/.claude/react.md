# React conventions

Keep reusable UI in components and side effects in explicit hooks. Prefer
semantic HTML and label controls. Handle empty, loading, and error states when
adding async features. Client state disappears on reload unless deliberately
persisted; do not promise cross-device persistence from browser storage.

Use Vitest and React Testing Library to assert rendered behavior and user
interactions, not implementation details. The starter counter is a working
example; replace it and its test together through the shared agent workflow.
Run tests and the typechecked production build before deployment.

The static deployment requires `dist/index.html`. Keep hashed JS/CSS under
`dist/assets/`, use root-relative URLs, and verify client-side route refreshes.
Uploaded releases are immutable; rollback selects a retained release. Changes
to browser storage formats should remain compatible with previously deployed
versions if rollback is expected.
