# Rails deployment

The deployment supports one Active Record SQLite database. Production database
configuration must use `ENV.fetch("DATABASE_PATH", "/data/app.db")`, a busy timeout
and WAL journaling. Litestream backs up that single file. Solid Queue, Solid Cache
and Solid Cable with separate database files require additional configuration
and backup infrastructure; the scaffold does not enable them.

Puma listens on `0.0.0.0:4000` (or `PORT`). `GET /health` must return HTTP 200 over
plain HTTP inside Docker. Caddy terminates HTTPS and forwards the public request.
Keep SSL redirects from interfering with the readiness route. Runtime secrets
arrive through `SECRET_KEY_BASE`; encrypted credentials additionally require an
explicit secret-management integration, not a master key baked into the image.

An existing application needs Gemfile, .ruby-version, config/application.rb,
config/environment.rb, config/database.yml, config/puma.rb and config.ru.
Bootstrap refreshes Dockerfile, .dockerignore, deployment scripts and workflows;
review generated files before adopting applications with custom build steps.
Ruby asset pipelines exposing assets:precompile run during image construction.
JavaScript package managers/build tools are not installed in the standard image.
Tests run `bundle exec rails db:prepare` then `bundle exec rails test` with
RAILS_ENV=test; release migrations run db:prepare before the traffic swap.
Keep runtime temporary files under tmp/log, which the image makes writable by
uid 65534. Persistent uploads require their own storage/backup design.
