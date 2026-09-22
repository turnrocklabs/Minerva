# Agent dev image for scripts/agent-container: one image for both compose
# services (dev = the harness, gateway = the host-side filter). Holds tools
# only — never source, credentials or harness state; those arrive per run as
# mounts chosen by agent.py. Pins below are kept equal to
# scripts/container-test/Dockerfile (tests/test_agent_launcher.py checks).
FROM ubuntu:24.04

ARG GODOT_VERSION=4.6.2
ARG GODOT_SHA512=b6e4d5a716085e9649905be2afe77f723f97853544fb33392ce3d32594c730a95d9eb4d1042ed51508904c9e1d996bd36b7c7a2bf4f93f5b1885e98d81b792e7
ARG NODE_VERSION=22.23.2
ARG NODE_SHA256=d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307
# Harness CLIs at exact versions (npm has no checksum pin; the exact version
# plus the registry's integrity check is the pin).
ARG CLAUDE_CODE_VERSION=2.1.278
ARG CODEX_VERSION=0.155.1

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip xz-utils python3 g++ make procps git ripgrep less tmux \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/godot.zip \
        "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" \
    && echo "${GODOT_SHA512}  /tmp/godot.zip" | sha512sum -c - \
    && unzip -q /tmp/godot.zip -d /tmp/godot \
    && mv "/tmp/godot/Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot \
    && rm -rf /tmp/godot /tmp/godot.zip

RUN curl -fsSL -o /tmp/node.tar.xz \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz

RUN npm install -g --no-fund --no-audit \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}" \
    && npm cache clean --force

# Runs as the invoking host uid (compose user:), which has no passwd entry;
# HOME is a tmpfs at run time, the harness config dir a per-session mount.
RUN mkdir -m 1777 /home/agent
ENV HOME=/home/agent

COPY gateway/ /opt/minerva-agent/gateway/
COPY forwarder.py minerva-session agent-env.sh agent-bashrc tmux.conf claude-mcp.json smoke.py \
     /opt/minerva-agent/
