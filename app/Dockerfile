# Multi-stage build producing an immutable `mix release`. App-name-agnostic:
# pass --build-arg APP_NAME=<otp_app>. No app name is hardcoded.
#
#   docker build --build-arg APP_NAME=my_app -t my_app:latest .
#
# Assumes the app has run `mix phx.gen.release` (provides config/runtime.exs +
# rel/ overlays). The bootstrap (Epic 6) guarantees this.
#
# Image tags verified against Docker Hub (Phoenix 1.8 needs Elixir >= 1.15):
#   builder hexpm/elixir:1.18.4-erlang-27.3.4.9-debian-bookworm-20260518-slim
#   runner  debian:bookworm-20260518-slim   (same debian build => glibc match)
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4.9
ARG DEBIAN_VERSION=bookworm-20260518-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ---- build stage -------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y build-essential git \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Deps first for layer caching.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config (config.exs + prod.exs); runtime.exs copied later so a
# runtime config change doesn't bust the dep-compile cache.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Build + digest static assets.
RUN mix assets.deploy
RUN mix compile

COPY config/runtime.exs config/
COPY rel rel

RUN mix release

# ---- runtime stage -----------------------------------------------------------
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale (Erlang wants UTF-8).
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

ENV MIX_ENV="prod"

# APP_NAME is required: the release dir + boot script are named after the OTP
# app. Fail the build loudly if it's missing rather than copying an empty path.
ARG APP_NAME
RUN test -n "${APP_NAME}" || (echo "ERROR: build requires --build-arg APP_NAME=<otp_app>" >&2 && exit 1)
ENV APP_NAME=${APP_NAME}

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/${APP_NAME} ./

USER nobody

# Endpoint serves only when PHX_SERVER=true (runtime.exs gate). Compose sets it.
# `start` runs the release in the foreground; the OTP app binary is APP_NAME.
CMD ["/bin/sh", "-c", "exec /app/bin/${APP_NAME} start"]
