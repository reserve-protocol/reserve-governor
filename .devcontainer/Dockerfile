FROM ubuntu:noble

ARG NODE_VERSION=24.15.0
ARG PNPM_VERSION=10.28.0
ARG FOUNDRY_VERSION=1.7.0
ARG CODEX_VERSION=0.128.0
ARG CLAUDE_CODE_VERSION=2.1.123
ARG OPENCODE_VERSION=1.14.30

ENV DEBIAN_FRONTEND=noninteractive \
    NVM_DIR=/home/vscode/.nvm \
    DISABLE_AUTOUPDATER=1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        sudo \
        tar \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN if getent passwd ubuntu >/dev/null; then \
        usermod --login vscode --move-home --home /home/vscode ubuntu; \
        if getent group ubuntu >/dev/null; then groupmod --new-name vscode ubuntu; fi; \
    else \
        groupadd --gid 1000 vscode; \
        useradd --uid 1000 --gid 1000 -m -s /bin/bash vscode; \
    fi \
    && echo "vscode ALL=(root) NOPASSWD:ALL" >/etc/sudoers.d/vscode \
    && chmod 0440 /etc/sudoers.d/vscode

USER vscode

RUN curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install "$NODE_VERSION" \
    && nvm alias default "$NODE_VERSION" \
    && npm install -g "pnpm@${PNPM_VERSION}"

ENV PATH=/home/vscode/.nvm/versions/node/v${NODE_VERSION}/bin:${PATH}

RUN curl -fsSL https://foundry.paradigm.xyz | bash \
    && /home/vscode/.foundry/bin/foundryup -i "v${FOUNDRY_VERSION}"

ENV PATH=/home/vscode/.foundry/bin:${PATH}

RUN npm install -g \
        "@openai/codex@${CODEX_VERSION}" \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "opencode-ai@${OPENCODE_VERSION}" \
    && npm cache clean --force

RUN mkdir -p \
        /home/vscode/.codex \
        /home/vscode/.claude \
        /home/vscode/.config/opencode \
        /home/vscode/.local/share/opencode
