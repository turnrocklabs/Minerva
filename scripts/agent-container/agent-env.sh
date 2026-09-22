# Sourced by agent-bashrc: the environment every shell in an agent session
# gets. HTTPS goes through the gateway's egress proxy (the container has no
# other network), the harness keeps its config, login and transcripts in the
# session's persistent home, and `claude`/`codex` are wrapped so they always
# reach Minerva, Docket and Nudge through the forwarder's loopback ports.
# Auto-update and telemetry are off; public HTTPS is available for research
# and downloads. `agent-upgrade` installs newer harness CLIs into the
# persistent home's tools/, which comes first on PATH. Login is the owner's
# interactive step; no credential is set here.
export HTTPS_PROXY=http://127.0.0.1:3128 HTTP_PROXY=http://127.0.0.1:3128
export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY"
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
export CLAUDE_CONFIG_DIR=/agent-home CODEX_HOME=/agent-home
# Toolchains are the builder image's (read-only /opt); cargo's registry cache
# and build state persist per session.
export CARGO_HOME=/agent-home/cargo
export PATH="/agent-home/tools/bin:$PATH:${MINERVA_AGENT_DIR:-/opt/minerva-agent}"
export DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

claude() {
	command claude --mcp-config "${MINERVA_AGENT_DIR:-/opt/minerva-agent}/claude-mcp.json" --strict-mcp-config "$@"
}

codex() {
	command codex -c check_for_update_on_startup=false -c analytics.enabled=false \
		-c 'mcp_servers.minerva.url="http://127.0.0.1:9315/mcp"' \
		-c 'mcp_servers.docket.url="http://127.0.0.1:3010/mcp"' \
		-c 'mcp_servers.nudge.url="http://127.0.0.1:8765/mcp"' "$@"
}
