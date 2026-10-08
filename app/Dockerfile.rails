# Multi-stage build for a Rails (Active Record/Puma) app. Framework: FRAMEWORK=rails.
# Copied into the generated app as `Dockerfile` by the bootstrap (prep_app).
#
#   docker build -t my_app:latest .
#
# Unlike the Phoenix image there is no APP_NAME build-arg: a Rack app boots by
# name-agnostic command (`puma`), not a named OTP release. SQLite is the only
# supported backend for the Rails path — the runtime carries libsqlite3 and
# the DB file lives on a droplet volume (Litestream replicates it; see
# deploy/compose.yaml).
#
# RUBY_VERSION must match .ruby-version. Bootstrap pins this argument from that
# file; RUBY_VERSION is an explicit override.
ARG RUBY_VERSION=3.3.12
ARG BUILDER_IMAGE="ruby:${RUBY_VERSION}-slim-bookworm"
ARG RUNNER_IMAGE="ruby:${RUBY_VERSION}-slim-bookworm"

# ---- build stage -------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

# build-essential + the sqlite3 headers compile the sqlite3 native gem.
RUN apt-get update -y \
  && apt-get install -y build-essential git pkg-config libsqlite3-dev \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install gems into a self-contained path we can copy wholesale into the runner.
# No BUNDLE_DEPLOYMENT: the scaffold ships no Gemfile.lock (it can't be generated
# without the target Ruby), so bundler resolves from the Gemfile here and the
# resulting image is the immutable, SHA-pinned artifact.
ENV BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_JOBS="4"

# Gemfile first for layer caching; Gemfile.lock copied when present.
# .ruby-version is required here too — the Gemfile pins `ruby file: ".ruby-version"`.
COPY Gemfile Gemfile.loc[k] .ruby-version ./
RUN bundle install && bundle clean --force

COPY . .
# Precompile Ruby asset pipelines when present; no production DB migrations.
RUN bundle exec rake -T > /tmp/rails-tasks \
  && if grep -q 'assets:precompile' /tmp/rails-tasks; then \
      RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile; \
    fi

# ---- runtime stage -----------------------------------------------------------
FROM ${RUNNER_IMAGE}

# libsqlite3-0: the shared lib the sqlite3 gem dlopen()s at runtime.
# bash: the compose healthcheck uses a /dev/tcp probe (no curl in slim).
RUN apt-get update -y \
  && apt-get install -y libsqlite3-0 bash ca-certificates tzdata \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV RAILS_ENV="production" \
    RACK_ENV="production" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    PORT="4000"

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /app /app

# Run unprivileged. uid 65534 == Debian 'nobody' — matches the chown the
# Litestream db_init sidecar applies to the shared /data volume, so the app
# (which creates the SQLite file + its -wal/-shm) owns what it writes.
RUN mkdir -p tmp/pids tmp/cache log && chown -R 65534:65534 tmp log
USER 65534:65534

EXPOSE 4000

# Puma binds 0.0.0.0:${PORT} (config/puma.rb). Caddy reaches it by container
# name; the healthcheck hits 127.0.0.1:4000.
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
