# MyApp — Rails application guidance

Rails with Active Record, SQLite and Puma. Keep controllers thin, put persistence
rules in models, and use service objects when orchestration needs a separate home.
Use Rails migrations and conventions; do not introduce additional infrastructure
without a concrete application requirement.

Run `bin/rails db:prepare` and `bin/rails test` before submitting changes. Tests
must exercise successful requests and persistence, alongside meaningful failure
cases. Keep production migrations additive so the previous release can serve
while a new release migrates and becomes healthy.

- `.claude/deployment.md` — runtime, backup and existing-app requirements.

Never commit credentials, database files or application data. Read the shared
agent workflow for role ownership and current dependency security review.
