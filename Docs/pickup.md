# Pickup — scansort multi-vault DCR chain FULLY CLOSED

STATE: `READY_FOR_NEXT_MISSION`

Last updated: 2026-05-18 (R1+S1 foreground + R2 background all pass; chain closed)

## What just shipped this cycle

| Commit | What |
|---|---|
| plugins `80ddc7e` | B-fallback rule engine: walks score-ranked rules in order, runs each rule's stages, evaluates conditions against extracted slot facts, fires-and-stops on first pass. Unblocks year-conditional routing. (DCR `019e3c91cf157ee4b7ebbe1602951731`) |

**Tests:** 299 lib + 4 manifest, all green. **Plugins HEAD:** `80ddc7e`. **Minerva HEAD:** `4b053e3f` (unchanged — change is plugin-side).

## Gates that passed (foreground, panel visible)

**R1 — single-vault regression** (baseline 4 rules, copy_to=["test"], one `test` vault):
- 7/7 routed → tax(4) / boat(1) / drawings(1) / utility(1)
- All source rows showed green "→ tax/boat/..." badges
- All vault subfolders auto-expanded with their docs
- Bottom status bar stable, "Processing <file>" persists

**S1 — multi-vault tax-year** (3 year-conditional rules, 3 year vaults):
- 4/4 tax docs routed: tax_2023(2), tax_2024(1), tax_2025(1)
- 3/3 non-tax docs left unprocessable in source (boat/drawings/utility — no rule matched, correct)
- All 3 tax_<year>_vault rows in Vaults pane, auto-expanded with year-specific docs
- Source rows for matched tax docs showed "→ tax_2..." badges
- Bottom bar stable

**S1 file outcomes (qwen2.5vl:7b):**
- 0624PEIM 1040 (2024) → tax_2024_vault → 2024_Padgett Business Services_1040.pdf
- 2023-Imran-1099 → tax_2023_vault → 2023_FIDELITY BROKERAGE SERVICES LLC_1099.pdf
- 2023-MorganStanley-MSFT-Bonus → tax_2023_vault → 2023_Morgan Stanley Capital Management, LLC._1099.pdf
- msft_w2 (ambiguous score across years) → tax_2025_vault → 2025_MICROSOFT CORPORATION_W-2.pdf (B-fallback walk fell through 2023→2024→2025 until conditions matched; model extracted year=2025)

## R2 result (closed 2026-05-18, same session as R1+S1 ship)

Single-vault regression with **scansort panel closed** (`minerva_close_editor editor_name="scansort · scansort_panel"`). Process called via MCP, no UI.

- `summary: moved=7 unprocessable=0 conflicts=0`
- `by_destination: {test: 7}` — matches R1 byte-for-byte
- `by_rule: {boat: 1, drawings: 1, tax: 4, utility: 1}` — matches R1 byte-for-byte
- 42 `document` state_changed events fired across runs; emission is panel-independent

R2 confirms the plugin emits events regardless of whether anyone is listening, and that the B-fallback engine produces identical routing decisions whether or not the UI is up.

**The full pickup → A2 → A2-bottombar → B-fallback DCR chain is done.** Next mission is whatever ships next on the scansort roadmap.

## Critical gotcha discovered this cycle (saved as session hint, promote to docket if recurring)

**Plugin binary install gap.** Scansort manifest's `entrypoint` is `./scansort-plugin` (root of plugin dir) but `cargo build --release` only writes to `target/release/scansort-plugin`. **There is NO automatic copy.** After every cargo build, you MUST `cp target/release/scansort-plugin scansort-plugin` before restarting Minerva, otherwise the running plugin is stale.

Symptom: cargo says "Finished", tests pass, you restart Minerva and the plugin behaves like the OLD code. Burned ~30 minutes this cycle debugging B-fallback that wasn't even loaded. Sequence that works: `cargo build --release` → kill any running scansort-plugin or Minerva (binary must be unlinked) → `cp target/release/scansort-plugin scansort-plugin` → relaunch.

Other gotchas (already saved as session hints):
- `minerva_plugin_start` / `_state` / `_stop` / `_restart` take `{"id": "..."}`, NOT `{"plugin_id": "..."}`
- `session_open_vault` only registers label↔path; the `.ssort` file must be `create_vault`'d separately
- Phase-1 scoring does NOT extract per-rule field facts; only B-fallback runs stages before conditions (NOW the case post `80ddc7e`)

## Cycle policy (carry-forward)

Each iter: snapshot lib → wipe state → restart Minerva → apply iter-config → run gate(s) → screenshot → verify → restore lib → commit if pass, file-bug+fix+retry if not. ALL bugs in ONE fix commit. 3 fix attempts per bug. Per-iter time cap 30min. Sub-agent for the heavier code change with `isolation: worktree`, enumerated file list, 25-30 turn budget.

## Validated paths

| What | Path | Notes |
|---|---|---|
| Source corpus | `/home/imran/temp/scansort-staging` | 7 PDFs — 4 tax-ish across 2023/2024/2025, 1 boat, 1 drawings, 1 utility |
| Test vault (R1) | `/home/imran/temp/test.ssort` | Created via create_vault; delete at cycle end |
| Year vaults (S1) | `/home/imran/temp/tax_<year>.ssort` | Same pattern |
| Library snapshot | `/tmp/lib_snapshot_iter.json` | Write at iter start; restore at iter end |
| Window ID | `xdotool search --name "Minerva"` | Returns inner WID; export `DISPLAY=:1` first |
| Minerva log | `/tmp/minerva_<tag>.log` | nohup target; grep "Score how well" vs "Answer the question" for Phase-1 vs stages calls |

## Hard rules (carry-forward, do not violate)

- Per-file `git add` only. No `git add -A` / `git add .`.
- No `--no-verify`. No `--no-gpg-sign`.
- No `vendor/` touches.
- No `git reset --hard`, no destructive ops without explicit auth.
- No force-push.
- Rubric: reliability → durability → cost (S≤100, M 101-1000, L>1000) → debuggability → discoverable (weight last two heavily).
- Cycle policy stop conditions: model not available, screenshot tooling failure, plugin won't start after 3 attempts, rebuild compile failure, anything requiring `vendor/`.
- Source is read-only — scansort copies to destinations, never alters source.
- pkill target is `godot`, not `Minerva` (process name is `godot --path ...`).

## Cold-start procedure for next session

1. `git -C ~/github/plugins log --oneline -5` — confirm `80ddc7e` at tip (B-fallback)
2. Read this pickup.md in full
3. Verify binary install: `md5sum ~/github/plugins/scansort/scansort-plugin ~/github/plugins/scansort/target/release/scansort-plugin` — if they differ, cp first
4. Pick next mission with the user — scansort multi-vault DCR chain is closed
