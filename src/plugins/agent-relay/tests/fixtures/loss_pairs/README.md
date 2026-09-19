# Paired loss corpus — screen pipeline vs harness session log

Eleven real turns, each held twice: what agent-relay's `read_turn` cleaning
pipeline produces from the terminal screen, and what the harness's own session
log recorded for the same turn. The point is to measure where the two differ,
so a future parser is built against measured loss rather than assumed loss.

Harnesses: Claude Code 2.1.277 and codex-cli 0.155.1, both at 120x40,
`TERM=xterm-256color`, driven through `expect` in a scratch directory outside
the repo. No harness configuration was changed to produce any pair.

## What each pair holds

| file | contents |
| --- | --- |
| `raw_terminal.tty` | byte-true PTY capture of the whole session, redacted (see below) |
| `screen.txt` | the rows the pipeline is fed, rendered from `raw_terminal.tty` |
| `cleaned.txt` | what the cleaning pipeline returns for `screen.txt` |
| `session_log.jsonl` | the harness's own records for the turn (empty file = the harness wrote none) |
| `ground_truth.txt` | the answer text, in the source form the harness recorded (empty = no record exists) |
| `erased_lines.txt` | lines a poll snapshot saw that the final screen no longer holds |
| `meta.json` | prompt, how ground truth was established, sizes, measurements, loss classes |

`meta.json.ground_truth_method` states per pair how the answer text was
established — a transcript field, a rollout field, or the screen alone.

## Measured table: loss class x harness x count

11 pairs: 6 Claude Code, 5 Codex. A count is the number of pairs in which the
class was measured, not an incident count.

| loss class | claude | codex | pairs |
| --- | ---: | ---: | --- |
| `indentation_stripped` | 6 | 5 | all |
| `viewport_ceiling_no_scrollback` | 6 | 0 | claude 01-06 |
| `completion_glyph_status_line` | 4 | 3 | claude 01-04, codex 01-03 |
| `chrome_interleaved_in_answer` | 3 | 1 | claude 02,03,05; codex 03 |
| `markdown_source_lost` | 3 | 1 | claude 02,03,05; codex 03 |
| `very_short_answer` | 2 | 2 | claude 01,04; codex 01,02 |
| `wrapped_lines` | 2 | 1 | claude 02,05; codex 03 |
| `tool_output_elided` | 1 | 0 | claude 04 |
| `interrupted_turn` | 1 | 1 | claude 05, codex 04 |
| `local_slash_command` | 1 | 1 | claude 06, codex 05 |
| `no_session_log` | 1 | 1 | claude 06, codex 05 |
| `partial_answer_absent_from_log` | 0 | 1 | codex 04 |
| `answer_lines_lost` | 0 | 0 | none |
| `answer_text_erased_between_polls` | 0 | 0 | none |
| `truncation_30k` | 0 | 0 | none |
| `ctrl_o_expand_affordance` | 0 | 0 | none |

### What the classes mean

- `indentation_stripped` — `chrome_filter::strip_border_columns` trims leading
  spaces as well as border glyphs, so list indent, code-block indent and the
  continuation indent of a wrapped line all reach the caller flattened to
  column 0. A wrapped continuation becomes indistinguishable from a new line.
- `viewport_ceiling_no_scrollback` — the screen holds no more rows than the
  viewport, so nothing above the top row is recoverable at any later time.
- `completion_glyph_status_line` — a trailing status line (`✻ Cogitated for 4s ·
  done 7:30 PM`, or bare `done 7:36 PM` for Codex) survives cleaning and is
  indistinguishable from answer text by position.
- `chrome_interleaved_in_answer` — the answer's own lines survive, but the
  recorded answer is not one contiguous run in `cleaned.txt`; per-message
  glyphs and tool-summary lines sit inside it.
- `markdown_source_lost` — the recorded answer carries markdown that the
  rendered screen does not.
- `wrapped_lines` — a recorded line longer than the terminal width arrives as
  several screen rows.
- `tool_output_elided` — the log holds a tool result the screen replaced with a
  one-line summary.
- `partial_answer_absent_from_log` — the screen holds answer text the harness
  did not record.
- `answer_lines_lost` — a recorded answer line is absent from `cleaned.txt`
  after whitespace and markdown normalisation. This is the only class that
  means outright text loss, and it did not occur.

### Classes that could not be obtained, and why

- **truncation** (`truncation_30k`) — not obtainable through the screen path on
  Claude Code, structurally. `chrome_filter::MAX_OUTPUT_CHARS` is 30 000, but
  Claude Code runs on the alternate screen: every capture measures
  `screen_rows_available == 40` with a 40-row viewport, so the screen can hold
  at most `rows * cols` = 4 800 characters. The pipeline's truncator cannot
  fire before the terminal has already dropped the text. The largest
  `cleaned.txt` in the corpus is 1 362 characters. Codex does accumulate
  scrollback (measured 41 and 64 rows for a 40-row viewport), so truncation is
  reachable there with a long enough answer; no such turn was captured within
  the run budget.
- **text erased between screen polls** (`answer_text_erased_between_polls`) —
  looked for and not found. Replaying each capture in 512-byte chunks (finer
  than any real poll) and diffing every snapshot against the final screen
  yields 8-29 vanished lines per pair, all of them chrome: spinner frames,
  partial repaints of a line that later appears complete, and startup
  placeholders. `erased_lines.txt` holds them. No vanished line carried answer
  text that the final screen lacked. The class is real in principle — it is the
  mechanism behind `viewport_ceiling_no_scrollback` — but at these answer
  lengths it did not bite.
- **`(ctrl+o to expand)` affordance suffix** — does not exist in Claude Code
  2.1.277. The byte string `ctrl+o` appears zero times in any capture, and
  `expand` zero times. A large tool result is collapsed silently to `Ran 1
  shell command` (see `claude/04_tool_output`: 1 091 characters of tool output
  in the log, nothing on screen, no affordance offered). Any filter rule
  written against that suffix is dead code against this version.
- **answer text lost outright above the viewport** — the class is established
  structurally (see truncation above) but is not held as a byte-true pair. The
  turn that would have carried it, a 1 491-character 400-line answer whose
  transcript exists, had its capture overwritten by operator error, and the
  live-turn budget was already spent. This is the corpus's known gap.
- **permission / approval dialogs** — out of the run budget. Codex does not
  record approvals in the rollout at all, so a pair would show a dialog on
  screen against an empty log side.

### Findings that are not "screen loses, log wins"

Three of the measured classes run the other way, and a parser design that
treats the harness log as the authority would lose data:

1. `no_session_log` — a session whose only activity is a local slash command
   writes **no log file at all**. Claude Code wrote no
   `~/.claude/projects/<slug>/<id>.jsonl` for the `/cost` session; Codex wrote
   no `~/.codex/sessions/<date>/rollout-*.jsonl` for the `/status` session.
   Both were verified by listing the directory after the run. The screen is the
   only record.
2. `partial_answer_absent_from_log` — Codex's rollout for an interrupted turn
   holds `task_started`, a `Reasoning` item and `turn_aborted`, and no
   assistant text. The 1 047 characters of partial answer visible on screen exist
   nowhere else. Claude Code, by contrast, does write the partial text block
   before the `[Request interrupted by user]` user record.
3. `answer_lines_lost == 0` everywhere — at these answer lengths the screen
   path loses formatting and adds noise, but does not lose words.

### Per-harness contrasts worth carrying forward

| | Claude Code 2.1.277 | codex-cli 0.155.1 |
| --- | --- | --- |
| screen model | alternate screen, `ESC[?1049h` at start | primary screen + scroll regions |
| scrollback | none; hard ceiling of `rows * cols` | grows; long answers stay readable |
| `## heading` | marker removed, replaced by `⏺` | marker kept literally |
| `**bold**` | markers removed | markers removed |
| fenced block | fence and language tag removed | fence and language tag removed |
| interrupted turn | partial text recorded | partial text not recorded |
| slash command | full-screen modal replaces the transcript | panel rendered inline in the transcript |

The alternate-screen result contradicts the calibration comment in
`src/profiles.rs`, which sets `alt_screen: false` for the `claude` profile with
the note "Claude Code scrolls the PRIMARY screen (scrollback grows)". Measured
across all six Claude captures here, it does not.

## Fidelity of the offline stand-in

The relay's own MCP tools were not available, so the pipeline was run offline.
What that does and does not reproduce:

- **Reproduced exactly.** `screen.txt` is rendered by `tools/vtreplay.c`, which
  links the same `libminerva-vt` shim over libghostty-vt that
  `src/gdextension/terminal` links, and extracts each row the way
  `TerminalSession.extract_row_text_screen` does: codepoints below U+0020
  become a space, the row is right-trimmed of spaces, rows are joined with
  `\n`. `cleaned.txt` is produced by `tools/clean_pipeline.rs`, which includes
  the crate's real `src/chrome_filter.rs` and runs `filter` -> `redact` ->
  `truncate(MAX_OUTPUT_CHARS)`, the `read_turn_core` pipeline for a session
  with no named filter rules installed (the default).
- **Not modelled: the row window.** `read_turn_core` reads rows
  `[turn_start_row, turn_end_row]` from `watcher::turn_rows`, and re-anchors on
  the echoed prompt when the caller supplies `echo_hint`. The corpus uses the
  documented full-viewport fallback instead, so the banner above the turn and
  the composer below it are present in `cleaned.txt` where an echo-anchored
  read would drop the banner. Anchoring can only remove leading noise, never
  restore text, so no loss count here depends on it.
- **Not modelled: timing.** `script(1)` records no timing, so the replay
  applies bytes as fast as it can. The real watcher waits for
  `host.terminal.wait` to settle (`settle_ms` 1500 for the claude profile) and
  then reads once. The 512-byte poll snapshots are therefore a far stricter
  test for inter-poll erasure than the watcher itself faces.
- **Not modelled: named filter rules.** No `filter_set` rule is installed, which
  is the default state of a fresh worker.

## Redaction

Redaction is applied to the `.tty` bytes as well as the derived text, with
equal-length replacements so that terminal column layout is unchanged and the
capture stays replayable. One replacement was needed: the account address in
Codex's `/status` panel became `user@example.test`. The corpus was then scanned
for API-key, token, JWT and private-key shapes; none were found. Claude
transcripts are reduced to their `user`, `assistant` and `system` records —
`attachment` rows carry the prompt scaffolding (environment snapshot, skill and
MCP listings) and are dropped. Codex rollouts keep `task_started`,
`task_complete`, `turn_aborted` and non-`developer` messages.

## Reproducing

```sh
# 1. offline pipeline runner (needs the crate's regex rlib)
cargo build                               # in src/plugins/agent-relay
RLIB=$(ls target/debug/deps/libregex-*.rlib | head -1)
rustc --edition 2021 -L target/debug/deps --extern regex=$RLIB \
      -o /tmp/clean_pipeline tests/fixtures/loss_pairs/tools/clean_pipeline.rs

# 2. renderer (needs the locally built VT shim)
SHIM=../../gdextension/terminal/ghostty-shim
cc -O2 -I$SHIM/src -o /tmp/vtreplay tests/fixtures/loss_pairs/tools/vtreplay.c \
   -L$SHIM/zig-out/lib -lminerva-vt -Wl,-rpath,$SHIM/zig-out/lib

# 3. check a pair
/tmp/vtreplay 120 40 claude/02_markdown_source/raw_terminal.tty | /tmp/clean_pipeline
```

`tools/drive-claude.exp` and `tools/drive-codex.exp` capture a new turn. Both
note the PTY constraints that make them work: Codex exits immediately unless
the slave is sized, its composer swallows the first Enter, and `expect` echoes
only what it reads, so waits must be `expect` timeouts rather than `sleep`.
