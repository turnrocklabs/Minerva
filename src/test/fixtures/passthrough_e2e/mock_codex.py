#!/usr/bin/env python3
"""Mock codex CLI for the chat-passthrough E2E harness (W7, DCR 019eb7f329).

Impersonates the SCREEN BEHAVIOUR of `codex` (v0.139.0) so the REAL agent-relay
plugin's turn-detector can drive a real PTY with NO LLM in the loop. The agent
relay's codex profile (minerva-plugins/agent-relay/src/profiles.rs) keys on:

  * prompt_box_regex  ^›\\s   (U+203A + space at line start) — idle/turn-end.
  * spinner_glyphs    "esc to interrupt" — the busy marker, must VANISH on done.
  * permission regex  (would you like to run | press enter to confirm or esc
                       | › 1. yes, proceed) — the dialog turn-end.
  * alt_screen false, bell_capable false, settle_ms 1500.

The screens are loaded byte-for-byte from the captured codex fixtures sitting
next to this file (codex_{idle_prompt,busy,done,permission}.txt). NEVER retype
them — they are the calibration source of truth.

REPL contract (one line of input per turn, read from stdin under a PTY):
  * on start                -> print the idle screen (turn-end baseline).
  * <any line>              -> print the busy screen ("esc to interrupt"),
                               sleep ~1.5s, print "MOCK-ANSWER: <reversed>" +
                               the idle screen again (busy marker scrolls out of
                               the 24-row viewport -> turn_completed fires).
  * "trigger-dialog"        -> print the permission-dialog screen, then block on
                               a SINGLE raw keystroke (read(1), no newline), then
                               print "DIALOG-ANSWERED: <key>" + idle screen.
  * "exit"                  -> print a goodbye line and exit 0.

The viewport the plugin reads is only ~24 rows tall, so each turn pads with
blank rows ahead of the fresh idle screen to evict the previous busy marker from
the detection window (last 40 lines, but the vt viewport is the real gate).
"""

import os
import sys
import time

FIX_DIR = os.path.dirname(os.path.abspath(__file__))


def _load(name: str) -> str:
    with open(os.path.join(FIX_DIR, name), "r", encoding="utf-8") as fh:
        return fh.read()


IDLE = _load("codex_idle_prompt.txt")
BUSY = _load("codex_busy.txt")
DONE = _load("codex_done.txt")
PERMISSION = _load("codex_permission.txt")

# Pad so the previous busy screen's "esc to interrupt" line is pushed out of the
# detection window (the watcher samples the terminal screen; the busy marker must
# not be on the latest screen at turn-end). Six blank rows are enough to clear
# the busy chrome while keeping the answer line within the recent scrollback the
# plugin's read_turn extracts (turn boundaries use total_scrollback_rows).
VIEWPORT_EVICT = "\n" * 6


def emit(text: str) -> None:
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    sys.stdout.flush()


def emit_idle() -> None:
    # Evict prior busy chrome, then render the byte-true idle prompt screen.
    sys.stdout.write(VIEWPORT_EVICT)
    sys.stdout.write(IDLE)
    sys.stdout.flush()


STDIN_FD = 0


def read_one_key() -> str:
    """Block for a single raw keystroke (no Enter). The PTY is in canonical
    (cooked) mode where a lone byte is held until a newline; flip to cbreak for
    exactly one byte so a bare keypress (e.g. 'y' from a dialog answer) is
    delivered immediately, then restore. Reads via os.read (NOT the text-mode
    reader, which misbehaves under the ghostty-vt PTY)."""
    try:
        import termios
        import tty
    except ImportError:
        termios = None
        tty = None

    if termios is not None and os.isatty(STDIN_FD):
        old = termios.tcgetattr(STDIN_FD)
        try:
            tty.setcbreak(STDIN_FD)
            b = os.read(STDIN_FD, 1)
        finally:
            termios.tcsetattr(STDIN_FD, termios.TCSADRAIN, old)
    else:
        try:
            b = os.read(STDIN_FD, 1)
        except OSError:
            return ""
    return b.decode("utf-8", "replace") if b else ""


def read_line() -> str:
    """Block for one line of input, reading raw bytes off the PTY fd until a CR
    or LF. CRITICAL: do NOT use sys.stdin.readline() — its TextIOWrapper raises
    on the ghostty-vt PTY Minerva uses (the buffered text reader mishandles the
    PTY's byte/line discipline). Returns '' on EOF/closed PTY."""
    buf = bytearray()
    while True:
        try:
            b = os.read(STDIN_FD, 1)
        except OSError:
            return ""
        if not b:
            # EOF only if we have nothing buffered; otherwise yield the line.
            return buf.decode("utf-8", "replace") if buf else ""
        if b in (b"\r", b"\n"):
            return buf.decode("utf-8", "replace")
        buf += b


def main() -> int:
    # Start: show the idle prompt so watch_start has a turn-end baseline.
    emit_idle()

    while True:
        line = read_line()
        if line == "":
            # EOF / PTY closed.
            return 0
        cmd = line.strip()

        if cmd == "exit":
            emit("Goodbye from mock codex.")
            return 0

        if cmd == "trigger-dialog":
            # Busy first (so the busy-gate observes a busy screen for this turn),
            # then the permission dialog which is the turn-end discriminator.
            sys.stdout.write(BUSY)
            sys.stdout.flush()
            time.sleep(1.5)
            sys.stdout.write(VIEWPORT_EVICT)
            sys.stdout.write(PERMISSION)
            sys.stdout.flush()
            # Wait for ONE raw keystroke (the dialog answer). No newline.
            key = read_one_key()
            emit("DIALOG-ANSWERED: %s" % key)
            emit_idle()
            continue

        # Normal turn: busy -> work -> deterministic answer -> idle.
        sys.stdout.write(BUSY)
        sys.stdout.flush()
        time.sleep(1.5)
        answer = cmd[::-1] if cmd else "(empty)"
        emit("MOCK-ANSWER: %s" % answer)
        emit_idle()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, BrokenPipeError):
        sys.exit(0)
