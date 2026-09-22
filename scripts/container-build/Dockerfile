# Builder image for scripts/container-build/build.py: the toolchains the repo's
# native build entry points expect, pinned. Holds no source; each build clones
# the requested commit from the repo's read-only object store.
FROM ubuntu:24.04

ARG ZIG_VERSION=0.15.2
ARG ZIG_SHA256=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239
ARG RUSTUP_VERSION=1.28.2
ARG RUSTUP_SHA256=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c
# Stable builds agent-relay; the nightly is scripts/build-godot-cef.sh's pin.
ARG RUST_STABLE=1.93.0
ARG RUST_NIGHTLY=nightly-2026-06-21

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git unzip xz-utils python3 python3-venv python3-pip \
        build-essential pkg-config scons cmake ninja-build \
        libx11-dev libxcursor-dev libxinerama-dev libgl1-mesa-dev libglu1-mesa-dev \
        libasound2-dev libpulse-dev libdbus-1-dev libudev-dev libxi-dev libxrandr-dev \
        libgtk-3-dev libnss3-dev libgbm-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && ln -s /opt/zig/zig /usr/local/bin/zig && rm /tmp/zig.tar.xz

# Toolchains live in world-readable /opt; builds run as the host uid with a
# private CARGO_HOME (see build.py), so only these binaries are shared.
ENV RUSTUP_HOME=/opt/rustup PATH=/opt/cargo/bin:$PATH
RUN curl -fsSL -o /tmp/rustup-init \
        "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/x86_64-unknown-linux-gnu/rustup-init" \
    && echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum -c - \
    && chmod +x /tmp/rustup-init \
    && CARGO_HOME=/opt/cargo /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain "${RUST_STABLE}" \
    && CARGO_HOME=/opt/cargo rustup toolchain install "${RUST_NIGHTLY}" --profile minimal \
    && CARGO_HOME=/opt/cargo cargo +"${RUST_NIGHTLY}" install --locked export-cef-dir \
    && rm /tmp/rustup-init && chmod -R a+rX /opt/rustup /opt/cargo

RUN mkdir -m 1777 /home/builder /work
ENV HOME=/home/builder
