# =============================================================================
# Multi-stage Dockerfile for the Phoenix LiveView demo application.
# Source: https://github.com/chrismccord/phoenix_live_view_example
#
# USAGE (from this repo root — no other repo needed):
#   docker build -t phoenix-demo:latest .
#
# The upstream source is fetched automatically in the first stage.
# =============================================================================

# ── Stage 0: fetch upstream source ───────────────────────────────────────────
FROM alpine/git AS source
RUN git clone --depth=1 https://github.com/chrismccord/phoenix_live_view_example /src

# ── Builder ───────────────────────────────────────────────────────────────────
FROM hexpm/elixir:1.14.5-erlang-25.3.2-debian-bullseye-20230227-slim AS builder

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git curl ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# --- Dependency layer (cached unless mix.exs / mix.lock change) ---
COPY --from=source /src/mix.exs /src/mix.lock ./
RUN mix deps.get && mix deps.compile

# --- Config ---
COPY --from=source /src/config config/
# Replace upstream runtime.exs with our patched version, which adds:
#   - server: true  (required to start HTTP in a release)
#   - PHX_HOST support
#   - Ranch/Cowboy transport_options for graceful drain
COPY runtime.exs config/runtime.exs

# --- Asset compilation ---
COPY --from=source /src/priv priv/
# The upstream repo omits priv/static/images/ entirely. Download the logo so
# the /image LiveView and the nav logo render correctly in production.
RUN mkdir -p priv/static/images && \
    curl -sSfLk https://github.com/phoenixframework/phoenix/raw/v1.6.16/priv/static/phoenix.png \
         -o priv/static/images/phoenix.png
COPY --from=source /src/assets assets/
RUN mix assets.deploy

# --- Application compilation + release ---
COPY --from=source /src/lib lib/
# Replace upstream page_live.ex: the original unconditionally calls
# Routes.live_dashboard_path/2, which is only compiled in :dev/:test.
# In a prod OTP release the function doesn't exist, causing a 500 on /.
COPY page_live.ex lib/demo_web/live/page_live.ex
RUN mix compile
RUN mix release

# ── Runtime ──────────────────────────────────────────────────────────────────
FROM debian:bullseye-20230227-slim AS runner

RUN apt-get update -y && \
    apt-get upgrade -y && \
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

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

RUN groupadd --gid 1000 app && \
    useradd --uid 1000 --gid app --shell /bin/sh --no-create-home app

COPY --from=builder --chown=app:app /app/_build/prod/rel/demo ./

USER app

ENV ERL_CRASH_DUMP=/tmp/erl_crash.dump \
    ERL_CRASH_DUMP_SECONDS=5 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

EXPOSE 4000

CMD ["/app/bin/demo", "start"]
