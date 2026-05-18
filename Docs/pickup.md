# Pickup — multi-vault tax-year routing scenario (foreground mode)

STATE: `READY_FOR_MULTIVAULT_MISSION`

Last updated: 2026-05-18 (post-bottom-bar fix, three iter cycles passed)

## Mission for this cycle

**Foreground-mode classification into multiple year-keyed vaults.** Same source corpus (`~/temp/scansort-staging`), but instead of one `iter_W0_vault`, the user opens N vaults named `tax_<year>.ssort` (e.g. `tax_2023.ssort`, `tax_2024.ssort`, `tax_2025.ssort`). Process should land each tax doc into the vault matching its classified year. Non-tax docs (Beneteau boat, GrandmaLizzy drawings) either stay in source OR route elsewhere — design choice for the cycle.

**Success criteria (strict, screenshot-verifiable):**
1. Panel's Vaults pane shows ALL `tax_<year>_vault` rows from `session_open_vault` calls
2. Each vault row auto-expands with its year's tax docs as children
3. Per-file source row badges show the correct `→ tax_<year>` target
4. Bottom status bar continues to show "Processing <file>" stably (no flicker)
5. Vault inventory of each year vault contains ONLY docs of that year
6. Non-tax docs handled per the chosen design (unclassified in source, or routed elsewhere)

## Open design question for the start of next session

The current `tax` rule has `copy_to: ["test"]` — a static destination label. Routing by year requires a way to choose target based on `classification.year`. Three approaches:

| Option | How | Cost | Trade-off |
|---|---|---|---|
| **A. Multiple rules with conditions** | Split into `tax_2023`/`tax_2024`/`tax_2025` rules, each with `conditions: {year == "2023"}` and `copy_to: ["tax_2023_vault"]`. Rule engine picks the matching rule per doc. | S — uses existing rule engine | New rule per year; library bloat |
| **B. Templated copy_to** | Enhance rule schema: `copy_to: ["tax_{year}_vault"]`. Rule engine substitutes from classification metadata before destination resolution. | M — schema + engine change | One rule, scales to any year |
| **C. Post-classify routing layer** | Single tax rule with `copy_to: []`; new plugin step inspects classification.year + session.vaults to choose target. | M — new code path | Bypasses rule engine; harder to debug |

Lean: **A first** (cheapest, works today), **B as follow-up** if the user wants templating broadly. Bring this to the user at the start of next session.

## Validated paths

| What | Path | Notes |
|---|---|---|
| Source corpus | `/home/imran/temp/scansort-staging` | 7 PDFs — 4 tax-related across 2023/2024/2025, 1 boat, 1 drawings, 1 utility |
| Year vault dir | `/home/imran/temp/tax_<year>.ssort` | Stable names; delete at cycle end |
| Library snapshot | `/tmp/lib_snapshot_iter.json` (write at iter start) | Restore at iter end (utility re-enabled, copy_to=["test"]) |
| Window ID | `xdotool search --name "Minerva"` | Returns inner WID; export DISPLAY=:1 first |

## Cycle policy (carry-forward from autonomous_loop_policy hint `019e3c5b038d`)

Each iter: snapshot lib → wipe state → restart Minerva → apply iter-config (open N vaults + source + rule changes) → run scenario → screenshot → verify → restore lib → commit if pass, file-bug+fix+retry if not. 3 fix attempts per bug. ALL bugs in one fix commit. Per-iter time cap 30min.

## What just shipped (carry-forward)

| Commit | What |
|---|---|
| `ccbcf9d` | L1 regression tests (kind-map + manifest validation) |
| `5ec5686` | A2 — session is truth, kill auto-state-restore + panel live-refresh bundle |
| `43c7bd5` | Per-file classification status badges in source pane |
| `11dc9a0` | Bottom status bar stability — "Processing <file>" persists, no chat-call flicker |

**Tests:** 297/0 plugins. **Plugins HEAD:** `11dc9a0`. **Minerva HEAD:** `78b1d22d` (unchanged — A2 fixes were plugin-side).

## Durable hints saved this cycle (find via docket_hint_query)

- `scansort/no_auto_state_restore_design_principle` — registries are Recent-only, never auto-displayed
- `scansort/panel_live_refresh_three_layer_fix` — 3-layer cohesion (plugin emit + panel route + tree render)
- `scansort/plugin_emits_state_changed_unconditionally` — headless test pattern
- `scansort-iteration/autonomous_loop_policy` — ratified cycle policy

## DCRs / bugs filed and resolved this cycle

- DCR `019e3c48f0da` — A2 architectural redesign (SHIPPED)
- Bug `019e3c590ed3` — chevron missing on vault rows (FIXED in `5ec5686`)
- Bug `019e3c591b3a` — rows should default-expand (FIXED in `5ec5686`)
- Bug `019e3c5f0fba` — process didn't emit kind=document (FIXED in `5ec5686`)

## Cold-start procedure for next session

1. `git -C ~/github/plugins fetch && git -C ~/github/plugins log --oneline -5` — confirm `11dc9a0` at tip
2. Read this pickup.md in full
3. `docket_get id=<multivault_dcr_id>` (filed at end of this session — see chat)
4. Decide rule-engine approach (A/B/C above) before implementing
5. Per cycle policy: snapshot library, apply iter-config, run, verify

## Hard rules (carry-forward, do not violate)

- Per-file `git add` only. No `git add -A` / `git add .`.
- No `--no-verify`. No `--no-gpg-sign`.
- No `vendor/` touches.
- No `git reset --hard`, no destructive ops without explicit auth.
- No force-push.
- Rubric: reliability → durability → cost (S≤100, M 101-1000, L>1000) → debuggability → discoverable (weight last two heavily).
- Cycle policy stop conditions: model not available, screenshot tooling failure, plugin won't start after 3 attempts, rebuild compile failure, anything requiring `vendor/`.

## Known gotchas (for next session ergonomics)

- **Bash `pkill || true` chains exit 1** in this harness — wrap each step or split into separate Bash calls. Several cleanup chains failed silently this session.
- **MCP catalogue staleness after Minerva restart** — `mcp__minerva__*` tools may disconnect; fall back to `curl http://localhost:9315/mcp`. Saved as hint `claude-code-mcp/tool_catalogue_misses_minerva_side_additions`.
- **Source manifest persistence**: `~/temp/scansort-staging/.scansort-state.json` carries skip state across runs; wipe between iterations or use a fresh source dir.
- **Empty input_schema → array args get stringified** by Claude Code MCP client. Use curl for array params. Saved as hint `claude-code-mcp/array_args_become_strings_with_empty_schema`.
