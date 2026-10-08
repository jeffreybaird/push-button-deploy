# Rails deployment

Production supports one Active Record SQLite database at
`ENV.fetch("DATABASE_PATH", "/data/app.db")`, WAL and a busy timeout. Litestream
replicates that file for recovery; unreplicated writes can be lost on host failure.
No additional Solid Queue/Cache/Cable databases or worker services are configured.

Puma listens on `0.0.0.0:4000` or `PORT`. `GET /health` checks database connectivity
and returns 200 over internal plain HTTP. Caddy terminates public HTTPS; keep
SSL redirects from interfering with readiness. Runtime uses `SECRET_KEY_BASE`;
never bake master keys or credentials into the image. Temporary writes belong
under tmp/log; persistent uploads need their own storage and backup plan.

GitHub and Gitea deploy gates run `./bin/check` when present. Fresh scaffolds
therefore require RuboCop, RSpec, strict Cucumber, 100% line/branch coverage and
current bundler-audit success before image build. GitHub PR staging uses the
same gate. Adopted apps without bin/check explicitly retain db:prepare + rails
test. A present failing or nonexecutable bin/check never falls back.

The image is immutable, SHA-pinned and runs as uid 65534, matching the volume
owner. Deploy prepares the schema with `bundle exec rails db:prepare` before
starting the new color; old code may remain active during migration and rollout.
Keep schema changes additive and compatible. Failed migration blocks the swap
but does not undo applied changes. Rollback repins an older image; it does not
undo database migrations. Shared Caddy routing and health determine availability.

An existing app needs Gemfile, .ruby-version, config/application.rb,
config/environment.rb, config/database.yml, config/puma.rb and config.ru.
Generation preserves its application source. Bootstrap refreshes Dockerfile,
.dockerignore, scripts and workflows, so review custom build requirements.
Ruby assets:precompile runs when available; no Node package manager is installed.
Managed guide updates are an explicit lifecycle operation, not source migration.

GitHub staging has separate data/backup configuration but shares the host and
privileged deployment credentials; it is not isolation for untrusted code.
Keep staging and deployment gates aligned. Secrets arrive over SSH in a private
runtime environment file, never in cloud-init, metadata or committed files.
