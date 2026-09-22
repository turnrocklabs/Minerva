# Test image for scripts/container-test.sh: the runtime the functional-tests CI
# job installs (Ubuntu 24.04 = ubuntu-latest), plus Xvfb for the app smoke.
# Holds tools only — never source, profiles or build output; those arrive per
# run as read-only mounts.
FROM ubuntu:24.04

ARG GODOT_VERSION=4.6.2
ARG GODOT_SHA512=b6e4d5a716085e9649905be2afe77f723f97853544fb33392ce3d32594c730a95d9eb4d1042ed51508904c9e1d996bd36b7c7a2bf4f93f5b1885e98d81b792e7
ARG NODE_VERSION=22.23.2
ARG NODE_SHA256=d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip xz-utils python3 g++ procps \
        libx11-6 libxcursor1 libxinerama1 libgl1 libglu1-mesa libegl1 \
        libasound2t64 libpulse0 libdbus-1-3 libudev1 libxi6 libxrandr2 \
        libgtk-3-0 libnss3 libgbm1 libxkbcommon0 libfontconfig1 \
        xvfb xauth \
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

# Runs as the invoking host uid (docker run --user), which has no passwd entry;
# give it a writable HOME and work root inside the container layer.
RUN mkdir -m 1777 /home/runner /work
ENV HOME=/home/runner

# Runner tooling rides in the image (its tag hashes this directory), so any
# tested revision runs under the same driver; the revision's own entry point
# (scripts/run-functional-tests.sh) comes from the snapshot.
COPY in-container.sh app-smoke.sh accounting.py /opt/container-test/
ENTRYPOINT ["/opt/container-test/in-container.sh"]
