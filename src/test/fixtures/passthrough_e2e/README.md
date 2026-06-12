# passthrough_e2e fixtures (W7 — chat-passthrough DCR 019eb7f329)

Fixtures for `src/test/test_passthrough_e2e.gd`, the headless token-free E2E
test of the entire chat-passthrough loop (real SingletonObject + real plugin
substrate + the REAL agent-relay plugin binary + a mock CLI in a real PTY).

## `codex_*.txt` — byte-true codex screens

Captured from **codex v0.139.0** and copied here **byte-for-byte** (via `cp`)
from the agent-relay plugin's own calibration fixtures:

    minerva-plugins/agent-relay/tests/fixtures/real/codex_{idle_prompt,busy,done,permission}.txt

NEVER retype these — they are the source of truth the plugin's codex turn-detector
is calibrated against (profiles.rs: `prompt_box_regex ^›\s`, busy marker
`esc to interrupt`, the permission-dialog regex + the option triple). Retyping
risks a one-codepoint drift that silently breaks detection. Re-copy from the
plugin repo if they ever need refreshing.

| file | role in detection |
|------|-------------------|
| `codex_idle_prompt.txt` | idle/turn-end baseline — has the `^› ` prompt line, no busy marker |
| `codex_busy.txt`        | busy screen — contains the `esc to interrupt` spinner marker |
| `codex_done.txt`        | a finished answer screen (prompt visible, no busy marker) |
| `codex_permission.txt`  | permission dialog — matches the permission regex + the Yes/Yes-and/No triple |

## `mock_codex.py` — the mock CLI

A stdlib-only stdin/stdout REPL that impersonates codex's SCREEN BEHAVIOUR (it
loads + prints the fixture bytes above). It runs under a real PTY launched by
Minerva's terminal extension, so it reads input as raw PTY bytes (`os.read` on
fd 0 — NOT `sys.stdin.readline()`, whose text-mode reader misbehaves under the
ghostty-vt PTY) and answers the dialog keystroke in cbreak mode (one bare key,
no Enter).

Behaviour:
- on start          → print the idle prompt screen.
- `<any line>`      → busy screen, ~1.5s, `MOCK-ANSWER: <input reversed>`, idle.
- `trigger-dialog`  → busy, then the permission dialog; block on ONE raw key;
                       print `DIALOG-ANSWERED: <key>` + idle.
- `exit`            → goodbye line, exit 0.

No LLM anywhere in the loop — possible because the passthrough transport has no
LLM (DCR #479). Zero token spend, no credentials.
