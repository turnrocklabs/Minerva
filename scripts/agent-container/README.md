# Agent containers

`agent.py` launches one harness (Claude Code or Codex) per session in a
hardened dev container; see its docstring for `build`, `start`, `attach`,
`stop` and where session state lives.

## Upgrading Claude Code or Codex in a session

The image's copy of each CLI is read-only, and `claude update` does not work
here (auto-update is off). Use `agent-upgrade` from the session shell instead:

```bash
agent-upgrade claude            # latest release
agent-upgrade claude 2.1.280    # or an exact version
agent-upgrade codex
```

The new version goes into `/agent-home/tools`, inside the session's
persistent home, so it survives container restarts and recreates and never
touches login or transcripts. It applies to that session only.

A harness that is already running keeps its old version: exit it to the
session shell and run `claude --resume` (or `codex resume`).

To go back to the image's version, rename the tools folder, for example
`mv /agent-home/tools /agent-home/tools.off`, and restart the harness.

New sessions start on the version pinned in the `Dockerfile`; bump it and run
`agent.py build` to move that baseline.

### Sessions started on an older image

Sessions started before `agent-upgrade` existed have neither the helper nor
the PATH entry. Install from the host, then point the session shell at it:

```bash
# host
docker exec minerva-agent-NAME bash -c '. /opt/minerva-agent/agent-env.sh;
  npm install -g --prefix /agent-home/tools --no-fund --no-audit @anthropic-ai/claude-code@latest'
# session shell, after exiting the harness
export PATH=/agent-home/tools/bin:$PATH; claude --resume
```

Once the session is recreated on a current image, this is automatic.
