# Agent containers

`agent.py` launches one harness (Claude Code or Codex) per session in a
hardened dev container; see its docstring for `build`, `start`, `attach`,
`stop` and where session state lives.

## One workspace, four repositories

Every session mounts its own clones of Minerva, minerva-plugins,
minervaservices and ccsandbox under `~/agent-work/TASK/`, so an agent can
work across all four. `--start-in REPO` only picks where the harness starts
(default `Minerva`, which loads Minerva's `CLAUDE.md`); it never reduces the
mounts. The old `--repo` filter is refused.

```bash
python3 ~/github/Minerva/scripts/agent-container/agent.py up NAME --harness claude --task TASK
python3 ~/github/Minerva/scripts/agent-container/agent.py up NAME --harness claude --task TASK --start-in ccsandbox
```

### Sessions started with a single repository

A session saved before this mounts only the repos it was started with.
`start` and `up` refuse it; `attach` still works but warns. To move it over,
exit the harness and the session shell (or `agent.py stop NAME`), then:

```bash
python3 ~/github/Minerva/scripts/agent-container/agent.py migrate NAME [--start-in REPO]
python3 ~/github/Minerva/scripts/agent-container/agent.py up NAME --harness H --task SAME_TASK --start-in REPO --mode shell
```

`migrate` keeps the old settings as `session.legacy.json` and never touches
the session home (login, transcripts) or its existing clone; the next start
clones only the missing repositories. Harness transcripts are indexed by
directory: starting in Minerva does not bring back a conversation held in
`ccsandbox`. To continue it, `cd` to the ccsandbox clone in the session shell
and run `claude --resume` there, choosing the conversation explicitly (or
migrate with `--start-in ccsandbox`).

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

## Notifications into a session (Linux)

Minerva can deliver `minerva_terminal_notify` messages into the tab a session
is attached to. The tab's host foreground is the `agent.py` launcher, so
Minerva looks through it: while the attach holds its lease, the launcher
writes `sessions/NAME/launcher.json` (its process group and the container's
init), and Minerva reads what is in front of the container's single tmux pane
from the host's `/proc`. Claude or Codex in front can receive a notification.
The pane shell in front refuses it, as does a lapsed or taken-over attach
(the tab then reads as the bare launcher). Anything Minerva cannot read
exactly (extra panes or windows, a restarted container) makes it hold.
Recognising the harness inside a container works on Linux hosts only.

A session attached before this existed needs the new launcher. Detach first
(`Ctrl+]` then `d` in the attached tab), then restart Minerva onto a build that
has it (coordinate this with the owner). Terminal ids can change across the
restart, so re-attach from a fresh terminal with the CURRENT Codex terminal id:

```bash
python3 ~/github/Minerva/scripts/agent-container/agent.py attach NAME --notify-to CURRENT_CODEX_TERMINAL_ID
```

If the old Minerva has already closed, the attach already ended with it: just
re-attach. The dev container keeps running throughout; nothing inside it
restarts.
