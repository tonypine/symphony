FROM debian:trixie

ARG MISE_VERSION=2026.5.6
ARG CODEX_VERSION=0.130.0
ARG CLAUDE_CODE_VERSION=2.1.142
ARG SYMPHONY_UID=1000
ARG SYMPHONY_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/home/symphony \
    MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_CONFIG_DIR=/opt/mise/config \
    MIX_ENV=prod \
    PATH=/opt/mise/shims:/home/symphony/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        autoconf \
        bash \
        bubblewrap \
        build-essential \
        ca-certificates \
        curl \
        git \
        libncurses-dev \
        libssl-dev \
        m4 \
        nodejs \
        npm \
        openssh-client \
        procps \
        socat \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g \
        @openai/codex@${CODEX_VERSION} \
        @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && npm cache clean --force

RUN curl https://mise.run | MISE_VERSION="v${MISE_VERSION}" MISE_INSTALL_PATH=/usr/local/bin/mise sh

RUN groupadd --gid ${SYMPHONY_GID} symphony \
    && useradd --uid ${SYMPHONY_UID} --gid ${SYMPHONY_GID} --create-home --shell /bin/bash symphony \
    && mkdir -p /opt/mise /app/symphony /app/docker \
        /workspace /workspace/logs /workspace/state /workspace/workspaces /workspace/repos \
        /home/symphony/.codex /home/symphony/.claude \
    && chown -R symphony:symphony /opt/mise /app /workspace /home/symphony

USER symphony

WORKDIR /app/symphony

COPY --chown=symphony:symphony mise.toml mix.exs mix.lock ./

RUN mise trust ./mise.toml \
    && mise install \
    && mise exec -- mix local.hex --force \
    && mise exec -- mix local.rebar --force \
    && mise exec -- mix deps.get --only prod

COPY --chown=symphony:symphony . /app/symphony
COPY --chown=symphony:symphony docker/entrypoint.sh /app/docker/entrypoint.sh

RUN mise exec -- mix escript.build \
    && chmod +x /app/docker/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["--config", "/workspace/symphony.yml"]
