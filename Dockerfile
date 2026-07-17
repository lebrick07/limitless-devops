# =============================================================================
# Multi-stage Dockerfile for the Phoenix LiveView demo application.
# Source: https://github.com/chrismccord/phoenix_live_view_example
#
# USAGE (from the application root, with this file in the infra repo):
#   docker build -f /path/to/Dockerfile -t phoenix-demo:latest .
#
# Or copy this file to the application root and run:
#   docker build -t phoenix-demo:latest .
# =============================================================================

# ── Builder ──────────────────────────────────────────────────────────────────
# hexpm/elixir provides Elixir + Erlang/OTP on Debian Bullseye.
# Using a pinned digest in production; using a tag here for readability.
FROM hexpm/elixir:1.14.5-erlang-25.3.2-debian-bullseye-20230227-slim AS builder

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git curl ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Hex + Rebar (package manager + build tool).
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# --- Dependency layer (cached unless mix.exs / mix.lock change) ---
COPY mix.exs mix.lock ./

# Fetch ALL deps (not --only prod) so the esbuild dev dependency is available
# for the asset compilation step below. The release will only ship runtime deps.
RUN mix deps.get && mix deps.compile

# --- Config (cached separately so source changes don't bust config layer) ---
COPY config/config.exs config/prod.exs config/test.exs config/dev.exs config/
# Replace upstream runtime.exs with our patched version, which adds:
#   - server: true  (required to start HTTP in a release)
#   - PHX_HOST support
#   - Ranch/Cowboy transport_options for graceful drain
COPY runtime.exs config/runtime.exs

# --- Asset compilation ---
COPY priv priv
# The upstream repo omits priv/static/images/ entirely. Download the logo so
# the /image LiveView and the nav logo render correctly in production.
RUN mkdir -p priv/static/images && \
    curl -sSfL https://github.com/phoenixframework/phoenix/raw/v1.6.16/priv/static/phoenix.png \
         -o priv/static/images/phoenix.png
COPY assets assets
# mix assets.deploy runs: esbuild default --minify && phx.digest
# esbuild downloads its binary (~4 MB) on first run; layer-cached afterwards.
RUN mix assets.deploy

# --- Application compilation + release ---
COPY lib lib
# Replace upstream page_live.ex: the original unconditionally calls
# Routes.live_dashboard_path/2, which is only compiled in :dev/:test
# (the route is gated by `if Mix.env() in [:dev, :test]`). In a prod OTP
# release the function doesn't exist, causing a 500 on every request to /.
# Additionally, Mix module is not available at runtime in releases, so
# Mix.env() cannot be used as a runtime guard — the link must be removed.
COPY page_live.ex lib/demo_web/live/page_live.ex
RUN mix compile
# mix release produces a self-contained OTP release under _build/prod/rel/demo.
# The release includes ERTS so the runtime image needs no Elixir/Erlang install.
RUN mix release

# ── Runtime ──────────────────────────────────────────────────────────────────
# Debian Bullseye slim: glibc-based so BEAM native libraries link correctly.
# Alpine/musl is avoided because the BEAM and some NIFs expect glibc.
FROM debian:bullseye-20230227-slim AS runner

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      libncurses5 \
      locales \
      ca-certificates \
      procps \
      dict \
      dict-wn \
      wamerican && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Locale required for Erlang string handling.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Non-root runtime user (UID/GID 1000).
RUN groupadd --gid 1000 app && \
    useradd --uid 1000 --gid app --shell /bin/sh --no-create-home app

# Copy the OTP release from the builder. ERTS is bundled — no Elixir/Erlang
# needed in the runtime image, which keeps it small and free of build tools.
COPY --from=builder --chown=app:app /app/_build/prod/rel/demo ./

USER app

# Runtime config — secrets MUST be injected via env vars, never baked in.
# PHX_SERVER is not used here; server: true is set in our patched runtime.exs.
ENV ERL_CRASH_DUMP=/tmp/erl_crash.dump \
    ERL_CRASH_DUMP_SECONDS=5 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

EXPOSE 4000

# PID 1: the release bin/demo script.
# The BEAM VM (OTP) correctly handles SIGTERM by calling :init.stop(), which
# triggers a supervised shutdown of all OTP applications in dependency order.
# The Endpoint supervisor terminates Cowboy, which drains open connections up
# to the transport_options shutdown_timeout configured in runtime.exs (60 s).
# No tini/dumb-init needed: there is only one process tree and OTP manages it.
CMD ["/app/bin/demo", "start"]
