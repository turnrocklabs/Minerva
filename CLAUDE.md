# Minerva agent instructions

## Engineering process

Before writing or reviewing code, read Docket `minerva:01a147ee08057a52ad61a4ba692c255a` (policy) and `minerva:01a147ee229d7787b8b5c4f905763b8d` (language rules).

Before every commit run `scripts/check-fast` (local-only host checks; never a push-lane step).

## This repo's mechanics

- Never point Godot at the live host `src` tree, including editor/headless/syntax checks; use an isolated copy with `--check-only`. Check for an editor-launched app and ask before launching another application. Container jobs and GATE-W are in the Master policy.
- Before pushing, scan the exact outgoing range: `scripts/scan-secret-history.sh --range "$(git merge-base origin/development HEAD)..HEAD"`. The script has no `--help`; this is its minimum usage.
- `$MINERVA_TERMINAL_ID` / `$MINERVA_TERMINAL_NAME` identify your Minerva terminal. For optional `minerva_terminal_notify`, use an unambiguous address from `minerva_terminal_list`, include `reply_to` when available, and send one line pointing to the Docket item. Outside Minerva, use the subscribed Docket item. The former `Agent Comms` notes tab is retired.
