# Non-interference proof artifacts (B5, 2026-06-11)

The invariant (DCR comment #477): watching a terminal must not change what
the child process receives — observation only, no probe sequences.

## Byte-level leg

`script -I <file> -c codex` records every byte the child receives on stdin.
Two runs in the same Minerva terminal (197x12), identical scripted writes
(two questions + /quit, CRs sent as separate writes):

- `noninterference_run_a.in` — NO watch session.
- `noninterference_run_b.in` — watch_start profile=codex notify_mode=all_turns
  (noisiest mode), with read_turn / read_clean / watch_status fired mid-run
  and turn detections emitting throughout.

Assertions (both PASS):
1. Stripped of the timestamped script(1) header/trailer lines, the two logs
   are byte-identical (`cmp`).
2. Both equal EXACTLY the concatenation of the sent writes — zero surplus
   bytes, so nothing anywhere in the watch path injected input.

Reproduce: strip first+last line of each log, `cmp` them, and `cmp` against
`printf 'What is 2+2? Answer in one word.\rName the largest planet. One word.\r/quit\r\n'`.

## Human leg (owner-judged, same session)

Owner drove codex by hand in a watched (all_turns) terminal — typed and
backspace-edited a question, approved a permission dialog via arrow keys,
interrupted a generation with Esc — while read_turns fired behind them.
Verdict: "No anomalies" (no dropped/doubled keystrokes, no cursor jumps,
no viewport scrolling, no flicker).
