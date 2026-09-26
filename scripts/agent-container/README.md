# Agent containers

`agent.py` launches one harness (Claude Code or Codex) per session in a
hardened dev container; see its docstring for `create`, `start`, `attach`,
`stop`, `status`, `info`, `readiness`, `list` and where session state lives.
Each session has a toolchain profile; see Toolchain profiles below.

Minerva drives the same launcher: Preferences > Containers > Agent Sessions
and the `minerva_agent_session_*` MCP verbs create, start, stop, inspect,
check readiness of and list sessions. A packaged Minerva carries this directory and
`scripts/container-build` as `agent-kit/` beside its executable (Linux) or in
`Contents/Resources/agent-kit/` (macOS), staged by
`scripts/stage-agent-kit.sh`; images build locally from these recipes.

## Sessions and folders

A session mounts the host folders it was created with. A git checkout is
cloned once into `~/agent-work/NAME/` and the clone is mounted, never the
checkout; any other folder is mounted at its own path, read-only unless
`--rw PATH` names it. `--start-in` picks where the
harness starts (default: the first folder). Docket projects are `--project`,
or else the `.dct` files found near the top of the folders.

```bash
python3 scripts/agent-container/agent.py create NAME --harness claude --folder ~/code/app --folder ~/notes
python3 scripts/agent-container/agent.py up NAME          # start if needed, then attach
python3 scripts/agent-container/agent.py up NAME --harness claude --folder ~/code/app   # create, start, attach
```

Sessions created before folders (a `task` and fixed repository names in
`session.json`) keep working: they start, stop and attach from the task
clones they already have, and `--task` still matches them.

## Attaching a session to a tab

Right-click a terminal tab and choose **Attach agent session here**, or call
`minerva_agent_session_attach` with the session and the terminal. Minerva
writes the attach command into that tab, which must be at a shell prompt, and
the launcher there holds the session's lease and its single tmux client.

The newest attach wins: attaching from a second tab takes the session over.
The first tab's tmux client is detached, it prints that the session is now
attached from another tab, and it returns to its shell; the binding (the
reply address notify uses) moves to the new tab. A takeover that fails to
establish leaves the first tab fronting. There is no `--takeover` flag and
no recovery command: a lease left by a crash never blocks an attach, and it
lapses on its own.

The session outlives Minerva. After Minerva exits (its tabs' launchers end
and release their leases) and relaunches, attach the session from any fresh
tab: the harness is still running in its tmux pane with its context on
screen, and its grants are per-session records, so notify works with no
further step.

## Dev tests inside a session

The image is built on the native builder image (`scripts/container-build/Dockerfile`),
so a session has the same pinned toolchains (Rust, Zig, SCons, CMake) plus
Godot, Node, Go (the version CI's `setup-go '1.26'` resolves, with
`GOTOOLCHAIN=local`, so a module needing a newer Go fails instead of
downloading one), the X/GL runtime libraries and Xvfb. From the Minerva clone:

```bash
scripts/dev-test.sh test/test_markdownlabel_tables.gd        # headless
scripts/dev-test.sh --display test/test_terminal_selection_copy.gd   # real window under Xvfb
(cd src/plugins/agent-relay && cargo test --locked)
```

`dev-test.sh` first runs `scripts/container-build/dev-natives.py`, which puts
each native binary in place: a read-only symlink into the host's build cache
when that component's inputs are unedited and the cache holds a verified
build, otherwise a local build from the working tree. It then imports the
project twice and runs the tests through `run-functional-tests.sh`. Anything
stale, unverifiable or failing stops the run with the reason. `agent.py
start` hands the session the builder image identity and the cache through a
read-only `natives.json`; cargo keeps its registry in `/agent-home/cargo`,
Go its module cache in `/agent-home/go`.

### Which image a session runs

The image tag is a hash of everything that goes into it (`agent.py`'s
`image_tag`), so changing the recipe or the files it copies gives a new tag,
and `agent.py build` builds it. A running session keeps the image it was
started on. Inside it, `echo $MINERVA_AGENT_IMAGE` names that image. On the
host, `python3 -c 'import sys; sys.path.insert(0, "scripts/agent-container");
import agent; print(agent.image_tag())'` names the one the checkout's recipe
builds. If they differ, or the variable is empty (an image from before it was
set), the session is on an older image. Recreate the session to move it, at a
coordinated checkpoint. Quick checks from the session shell:

```bash
echo "$MINERVA_AGENT_IMAGE"                  # empty: predates this check
go version && go env GOTOOLCHAIN             # go1.26.x, local; missing: predates Go
python3 -c 'import json; m = json.load(open("/run/minerva-natives.json")); print(m["builder_image"], m["cache"])'
```

The last line is the builder image (tag and id) and native cache the session
was handed (see above). `dev-natives.py` reports, per component, whether it used that
cache or built locally.

## Planned jobs and drain

A planned job is one command at an exact revision of a session's clone, run
in its own container of the session's image (the compose `job` service: no
network, read-only root, host uid) with CPU, memory and time limits:

```bash
agent.py run-job NAME --rev abc1234 --command 'scripts/dev-test.sh test/test_x.gd' \
    --seconds 900 --memory 6g --cpus 4 --artifact logs/report.json
agent.py job-status NAME [JOB]        # running, or succeeded / failed / timed_out / interrupted / unknown
agent.py job-log NAME JOB
agent.py drain NAME [--wait S]        # no new jobs; stop the running ones (interrupted, never retried)
agent.py drain NAME --lift
```

The revision is checked out fresh, so uncommitted changes in the clone never
reach a job; the result records the commit that ran and whether the clone was
dirty. Minerva's twins are `minerva_agent_session_run_job`, `_job_status`,
`_job_log`, `_drain` and the Jobs section of Preferences > Containers.
`jobs.py` documents the classification rules.

## Toolchain profiles

A profile names the tools a session needs, each with an optional minimum
version, the arguments that print it, and how to provision it. A session
picks one when it is created (`--profile`, the Profile choice in Preferences
> Containers, or `profile` on `minerva_agent_session_create`); a session
created without one uses `default`. `info` shows the profile and its tools,
and `readiness` checks against it (`--profile` there is a what-if only).

Profiles are data, never code:

- `profiles.json` here ships `default` (the image's toolchain) and
  `godot-4.7` (for projects that declare Godot 4.7 features).
- Your own file, named by `$MINERVA_AGENT_PROFILES`, adds profiles and
  replaces shipped ones of the same name. Minerva sets it to
  `agent-profiles.json` in its data directory; **Edit profiles…** in the
  panel creates and opens it. `agent.py profiles` (or
  `minerva_agent_session_profiles`) lists what is on offer, and a profile
  that does not parse shows its error.

```json
{"go-1.27": {"description": "Go 1.27", "extends": "default",
  "tools": {"go": {"min": "1.27", "version_args": "version",
    "provision": {"version": "1.27.0",
                  "url": "https://go.dev/dl/go{version}.linux-amd64.tar.gz",
                  "checksum": "<sha256 from go.dev/dl>", "bin": "go/bin/go"}}}}}
```

A tool's `provision` names an official download (an https zip or tar
archive; `{version}` is substituted), a `checksum` (sha256 or sha512 hex) or
the channel's own `checksum_url`, and `bin`, the executable's path inside the
archive. A profile never carries a binary. `agent.py provision NAME` (the
panel's **Provision missing tools**, `minerva_agent_session_provision`) runs,
inside the running session, the provisioning of every tool readiness would
report missing or too old: download through the session's egress, verify,
unpack into `/agent-home/tools/opt/TOOL-VERSION` and link
`/agent-home/tools/bin/TOOL`, which is first on the session's PATH. The image
is not rebuilt; the tool is private to the session and survives restarts.
Restart the harness to pick it up. Planned jobs run in their own container
without the session home, so they still see the image's tools.

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

## Grants: notes, notify and the Docket identity

What a session may do beyond the fixed gateway policy is one record Minerva
keeps, `sessions/NAME/control/grants.json`: the notes it may read, the notes
it may write (write implies read) and whether it may notify. With the notify
grant a session may notify any Minerva tab with a harness in front except its
own; there is no list of targets. Change it any time, running or not, from
Preferences > Containers > Agent Sessions (Grants), with
`minerva_agent_session_grant` / `minerva_agent_session_revoke`, or:

```bash
python3 scripts/agent-container/agent.py grant NAME --note-write NOTE_ID --notify
python3 scripts/agent-container/agent.py revoke NAME --note-write NOTE_ID
```

The gateway reads the record on every call, so the next call follows it; no
re-attach is involved. A session started by an earlier
`agent.py` gets its `grants.json` from its `notes.json` (notify on) when it
next starts or its grants next change. Until it restarts, its gateway still
reads `notes.json` (kept in step with every change) and its notify targets
from `attach --notify-to`.

## Docket: the session's assigned work only

The session reaches Docket only for the work assigned to it. Its principals
are the identity and role registered for it (`minerva_session_register` with
`container`); Minerva copies them into `grants.json` (`agent.py identity`)
whenever that registration changes. An item is the session's when its
`assigned_to` or `directed_to` is exactly that identity or role; its chain
adds those items' parents up to the first `wr:objective`. On the chain it may
read items, comments and attachments and add comments, attachments and child
items; it changes fields only on its own items, with `holder` stamped as its
identity, and a protected field (W1 contract) only while it holds the claim
(`docket_claim`). Anything else is refused with `docket_out_of_scope`, naming
the item and the identity. `gateway/docket_scope.py` evaluates this on every
call from the current records. `agent.py readiness NAME` reports whether the
Docket service offers the claim verbs (an older Docket build does not: then
claims and protected changes are refused).

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
restart, so re-attach from a fresh terminal:

```bash
python3 scripts/agent-container/agent.py attach NAME
```

If the old Minerva has already closed, the attach already ended with it: just
re-attach. The dev container keeps running throughout; nothing inside it
restarts.
