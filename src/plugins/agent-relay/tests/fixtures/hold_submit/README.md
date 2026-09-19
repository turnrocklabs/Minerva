# Hold-state and submit-confirmation corpus

Byte-true terminal captures of the screen states a relay write must be **held**
on, of what a **successful submit** looks like a second after the write, and of
what the **harness's own queue** does to a message written while a turn is in
flight. Companion to `../loss_pairs/`, which measures the read side.

Harnesses: Claude Code 2.1.278 and codex-cli 0.155.1, both at 120x40,
`TERM=xterm-256color`, driven through a PTY (`tools/drive.py`) in a scratch
directory outside the repo. No harness configuration file was changed and no
hook was installed. Two fixtures were reached with a **launch flag**
(`claude --permission-mode default`, `codex -a on-request -s read-only`); each
says so in its `meta.json.launch`.

## What each fixture holds

| file | contents |
| --- | --- |
| `raw_terminal.tty` | byte-true PTY capture, truncated at the instant captured |
| `screen.txt` | the rows the detector is fed, rendered from `raw_terminal.tty` |
| `meta.json` | class, how the ground truth was established, detector verdict |

`screen.txt` is what `host.terminal.wait` hands `watcher.rs` — the extracted
screen rows, **not** chrome-filtered text. `watcher.rs:818` passes that string
straight to `detector::run`, so the stored bytes reproduce the live verdict.

The queue fixtures keep the whole run instead: `raw_terminal.tty`,
`events.jsonl` (every key written and every mark, with its byte offset and
millisecond), `reads.jsonl` where recorded (per-read timestamps), and
`screens/NN_*.txt` rendered at the interesting moments.

## 1. Hold states

An independent reader can confirm each class by eye from `screen.txt`.

| fixture | class | detector verdict | held? |
| --- | --- | --- | --- |
| `hold/claude_permission_dialog` | permission dialog (Write tool) | `none` | **NO — finding 1** |
| `hold/claude_question_chooser` | AskUserQuestion chooser | `input_requested` / `permission_dialog` | yes |
| `hold/claude_trust_folder` | trust-folder prompt | `none` | **NO — finding 2** |
| `hold/claude_model_menu` | unknown menu (`/model`) | `input_requested` / `permission_dialog` | yes |
| `hold/codex_trust_directory` | trust-directory prompt | `none` | **NO — finding 2** |
| `hold/codex_update_available_menu` | unknown menu (update offer) | `none` | **NO — finding 3** |
| `hold/codex_model_menu` | unknown menu (`/model`) | `input_requested` / `permission_dialog` | yes |

Four of seven hold states are not classified `input_requested`. None of them
false-fired `turn_completed` either: every one returned `none`, so a watcher
would keep waiting rather than write — but nothing in the detector tells a
writer that the screen is a menu.

**Finding 1 — the permission dialog is missed by a window, not by a regex.**
`detector::run` matches `permission_dialog_regex` only within
`last_n_lines(screen, 20)`. In `hold/claude_permission_dialog` the caret line
`❯ 1. Yes` *does* match the regex, but it sits 22 lines from the end of the
40-line screen: the dialog is drawn mid-viewport and the rows below it are
blank, and blank rows count. The same screen's only `prompt_box` match is 35
lines from the end, outside the 10-line prompt window, which is the sole reason
it does not report `turn_completed` instead. The margin is the trailing blank
rows of the viewport.

**Finding 2 — trust prompts match no token at all.** Claude Code's trust prompt
offers **unnumbered** options (`❯ No, exit` / `Yes, I trust this folder`) under
the footer `Enter to confirm · Esc to cancel`; the claude profile wants
`[❯>]\s*\d+\.\s`, `enter to select` or `(y/n)`, and none is present. Codex's
trust prompt offers `› 1. Yes, continue` under `Press enter to continue`; the
codex profile wants `would you like to run`, `press enter to confirm or esc` or
`› 1. yes, proceed`. Both are the FIRST screen a freshly started harness draws,
i.e. exactly the screen a relay meets when it starts a session in a directory
the harness has not seen.

**Finding 3 — the codex update offer is one Enter away from a package install.**
`› 1. Update now (runs npm install -g @openai/codex)` / `2. Skip` /
`3. Skip until next version`, footer `Press enter to continue`. The detector
returns `none`. Its `› 1.` line matches `prompt_box_regex`; it escapes a
`turn_completed` verdict only because it is 35 rows from the end of a 40-row
screen, outside the 10-row prompt window. `hold/codex_model_menu` shows how
thin that margin is: there the equivalent `› 1. gpt-6-astra (current)` line is
7 rows from the end, inside the window, and only the footer phrase
`Press enter to confirm or esc` — matched one row from the end — wins the
precedence and turns the verdict into `input_requested`.
Draw the same menu nearer the bottom — or trim trailing blank rows anywhere in
the read path — and the detector reports `turn_completed` on it. This is not
hypothetical: while capturing this corpus an automated Enter landed on this
menu and started `npm install -g @openai/codex` in the owner's global node
install (see *Incidents* below).

**Finding 4 — `is_busy` reads false mid-turn while the composer holds a draft.**
`queue/claude_queue/screens/02_second_message_typed.txt` is taken 3 s into a
live turn: the working row `✻ Cooking… (3s · ↓ 87 tokens)` is on screen, but
the footer has collapsed from `… · esc to interrupt · ← for agents` to
`⏵⏵ auto mode on (shift+tab to cycle)`, and `esc to interrupt` is the claude
profile's only spinner glyph. `detector::is_busy` returns **false** on a screen
whose turn is demonstrably in flight, whenever the composer has draft text in
it. The busy-gate in `watcher.rs:812` is one prompt-row position away from
opening on that screen.

### Codex approval prompt — NOT OBTAINED

Three live attempts, no dialog. Reasons, in order:

1. codex-cli 0.155.1 has dropped the `untrusted` and `on-failure` approval
   policies — `-a` accepts only `on-request` and `never`. There is no longer a
   flag that forces an approval prompt; the model decides.
2. With `-a on-request -s read-only` and a prompt that must write a file, the
   exec tool never reached the approval point: it failed twice with
   `Broken pipe (os error 32)` and the model reported the failure as the turn's
   answer. The same failure occurred with the outer sandbox disabled, and the
   session banner reports `⚠ 2 startup issues (1 MCP)` — codex routes shell
   execution through a code-mode MCP host that does not come up in this
   environment.

The closest existing evidence is `../real/codex_permission.txt` from the B5
HITL, which is cleaned text rather than a byte-true capture. Two codex hold
menus of the same structural shape (`› 1. …` + a `Press enter …` footer) ARE in
this corpus: `hold/codex_trust_directory` and
`hold/codex_update_available_menu`.

## 2. Submit confirmation

| fixture | what it shows |
| --- | --- |
| `submit/claude_composer_typed_before_enter` | text in the composer, no echo — the BEFORE side |
| `submit/claude_typed_submit_ok` | 1 s after Enter: echo present, composer bare `❯`, `esc to interrupt` live |
| `submit/claude_chunk_submit_ok` | the same message and its CR in ONE write: also submitted |
| `submit/claude_idle_with_ghost_suggestion` | idle composer that LOOKS like it holds unsent text |
| `submit/codex_composer_typed_before_enter` | text in the composer, no echo — the BEFORE side |
| `submit/codex_typed_submit_ok` | 1 s after Enter: echo present, composer back to its placeholder |
| `submit/codex_chunk_stuck_in_composer` | the failure shape: text still in the composer, no echo, not busy |
| `submit/codex_chunk_after_extra_enter` | one extra Enter submits it, exactly once |

**A successful submit, measured.** One second after the Enter byte:

- Claude Code — the sent text is echoed in the transcript as `❯ <text>`, the
  composer row is a bare `❯`, and the footer carries `esc to interrupt`.
- codex — the sent text is echoed as `› <text>`, the composer row shows the
  placeholder `› Ask Codex to do anything` (an empty codex composer is never
  blank), and `• Working (0s • esc to interrupt)` is on screen.

**Finding 5 — the paste-failure shape is codex-only.** Writing the message and
its CR as a single `write()` left the text sitting in codex's composer with no
echo and no working row, and the capture did not change between t+1200 ms and
t+4200 ms (identical byte offset — the harness sent nothing at all), so it is a
settled state and not a race. One extra Enter submitted it, once. The identical
write into Claude Code 2.1.278 **submitted normally**; no paste-stuck state was
producible on that harness.

**Finding 6 — "composer empty" is not readable from the extracted rows on
Claude Code.** After a turn, Claude Code draws a **dim suggestion** inside the
empty composer: `ESC[2m` + text + `ESC[22m` (see
`submit/claude_idle_with_ghost_suggestion/raw_terminal.tty` under `cat -v`).
The extracted row is `❯ Reply with exactly the word PONG and nothing else.` —
character-for-character the shape of "the write is still sitting there
unsent". The suggestion is not always the previous message: in the same session
it was once `create notes.txt with hello`, which was never typed. An extra
Enter written against it submits nothing. Any "send one more Enter when the
composer is not empty" rule keyed on row text will fire on this state, and any
"confirm the composer is empty" rule will fail a submit that actually worked.
Row text alone cannot separate the two; the dim SGR attribute can, and it is
dropped by `extract_row_text_screen`.

**Finding 7 — a queued send is byte-indistinguishable from a completed send on
Claude Code.** See `queue/claude_queue/screens/03_queued.txt`: the message is
echoed as `❯ <text>` in the transcript exactly as a sent message is. The only
difference is the composer row, which reads `❯ Press up to edit queued
messages` instead of a bare `❯` — i.e. the composer is *not* empty. So
"echo present AND composer empty" is not merely sufficient-but-strict: it
rejects a send that the harness accepted.

## 3. Harness queue measurement

Both harnesses queue a message written while a turn is in flight and run it
next, in order. Measured once per harness, on the live harnesses.

| | Claude Code 2.1.278 | codex-cli 0.155.1 |
| --- | --- | --- |
| accepted while busy | yes | yes |
| what the screen shows while queued | message echoed as `❯ <text>` + hint row `ctrl+x ctrl+s to send now`; composer placeholder `❯ Press up to edit queued messages` | composer back to `› Ask Codex to do anything`; message shown as a `↳ <text>` row above it, NOT echoed as `› <text>` |
| time queued in this run | 9.0 s | 42.4 s |
| dequeue delay after turn end | < 1 s sampled; ~70 ms interpolated | **22 ms**, directly timed |
| order preserved | yes | yes |
| messages lost | 0 | 0 |

Claude Code's figure is interpolated because that run predates the per-read
timestamps: the 1 s sample window is direct, and inside it a byte-offset bisect
of the same capture puts the turn-1 `done` row at byte 39902 and the clearing of
the queued placeholder at byte 40142 — 240 bytes at the 3.4 byte/ms rate
measured across that window. Codex's figure is direct from `reads.jsonl`:
the last answer row of turn 1 at t=209244 ms, the queued message echoed as a
`› ` transcript line at t=209266 ms.

So the design that trusts harness-side queueing is correct for both harnesses.
The catch is not the queue, it is the screen: on Claude Code the queued state
reproduces the echo half of the submit signature (finding 7), and on codex the
queued state reproduces the *empty composer* half while withholding the echo.
A writer that samples once and asks "did it send?" can read either state wrong
unless it looks at the marker (`↳` vs `›`) or the placeholder row.

## 4. Reproducing

```sh
# renderer (shared with the loss_pairs corpus)
SHIM=../../../gdextension/terminal/ghostty-shim
cc -O2 -I$SHIM/src -o /tmp/vtreplay ../loss_pairs/tools/vtreplay.c \
   -L$SHIM/zig-out/lib -lminerva-vt -Wl,-rpath,$SHIM/zig-out/lib

# detector runner (includes the crate's real detector.rs + profiles.rs)
cd ../../..                                   # src/plugins/agent-relay
cargo build
D=target/debug/deps
rustc --edition 2021 -L $D \
      --extern regex=$(ls $D/libregex-*.rlib|head -1) \
      --extern serde=$(ls $D/libserde-*.rlib|head -1) \
      -o /tmp/detect_runner tests/fixtures/hold_submit/tools/detect_runner.rs

# check any fixture
F=tests/fixtures/hold_submit/hold/claude_permission_dialog
/tmp/vtreplay 120 40 $F/raw_terminal.tty | diff - $F/screen.txt && echo "screen reproduces"
/tmp/detect_runner claude < $F/screen.txt     # → meta.json.detector_verdict

# any moment of a queue run
head -c 17657 queue/claude_queue/raw_terminal.tty > /tmp/p.tty
/tmp/vtreplay 120 40 /tmp/p.tty
```

`tools/drive.py` is the PTY driver that produced every capture: it records
every master byte, every key written and a mark per step, each with a byte
offset and a millisecond, so any instant of a run can be re-rendered. It scrubs
`CLAUDE*` environment variables from the child so a nested harness starts
clean.

## 5. Redaction

No redaction was needed. The captures were scanned for API-key, bearer-token,
JWT and private-key shapes, for `/home/<user>` paths and for e-mail addresses;
none are present. Paths that appear are the uid-keyed scratch directory the
sessions ran in, the same shape the `loss_pairs` corpus already carries. No
session log or transcript is included in this corpus.

## 6. Incidents during capture

Recorded because they are the same class of accident this corpus exists to
prevent.

1. **A blind Enter installed a package.** The very first codex launch drew the
   update-available menu (`hold/codex_update_available_menu`); the capture plan
   pressed Enter to get past what it assumed was a prompt, which selected
   `1. Update now` and started `npm install -g @openai/codex`. Killing the PTY
   left the install half-finished: the global `codex` bin symlink was gone and
   the platform package's `package.json` was missing, so `codex` would not
   start. Repaired by recreating the symlink and restoring that one metadata
   file from the published tarball; `codex --version` now reports 0.155.1,
   upgraded from the 0.154.0 that was installed before. The install had already
   replaced the packaged binaries before it was interrupted, so the global
   `codex` on this machine is 0.155.1 from here on, not 0.154.0.
2. **Codex recorded a trust entry.** Answering codex's trust prompt appended a
   `[projects."…/scratchpad/p2t1/work/codex_a"] trust_level = "trusted"` stanza
   to `~/.codex/config.toml`. That is the harness writing its own state, not a
   configuration change made to drive it; it is harmless and was left in place.
