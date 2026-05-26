# Pickup

STATE: `DCR1+2+3 CODE-COMPLETE · HITL FAILING · MINERVA DOES NOT RUN FROM CI BUILD`

Last updated 2026-05-26 after compaction prep. The plugin marketplace
end-to-end pipeline is code-complete and pushed. User attempted the HITL
test (download Minerva from CI, install a plugin from marketplace).
**Minerva does not run** from the downloaded artifact. Cause unknown;
that's where work resumes.

---

## 0. RESUME — read this first

The autonomous chain through 3 DCRs completed and pushed. Then the user
ran a CI build of Minerva on the swarm branch via workflow_dispatch,
downloaded the artifact, and Minerva failed to launch. The failure mode
was NOT captured — that's what we debug next session.

**Most likely root causes** (in rough order):
1. **Parse error on autoload chain** — my new `MarketplaceBrowseDialog.gd`
   declares `class_name MarketplaceBrowseDialog`. Class_name registration
   happens at project import. A class_name collision or a typo would
   prevent project load. (Local headless boot showed no parse error,
   but CI export uses a fresh class registry.)
2. **Missing GDExtension binaries in the CI artifact** — the build flow
   downloads godot-cef/godot-wry/terminal sibling artifacts; if any
   download failed silently the .app/.exe would load but crash on first
   extension use.
3. **My new `_browse_button` button-add edit to PluginManagerPanel.gd**
   had a subtle bug (e.g. variable initialised but signal connect on a
   null) that only fires when PluginManagerPanel actually instantiates.
4. **GitHub Actions release of Minerva**: the build may have failed
   outright with my new files included. Check Actions UI.

**Debug starting points:**
- Open the failed run at https://github.com/turnrocklabs/Minerva/actions
  — was the build itself red?
- If build green: download artifact, run from terminal with
  `Minerva.exe 2>&1 | tee minerva-launch.log` to capture stderr.
  Look for "SCRIPT ERROR: Parse Error", "Failed to load script", or
  "Could not find class".
- Try side-load first (existing "Install Plugin..." button on a local
  manifest) — if THAT fails, the panel itself is broken.
- If Browse button works but Install fails, the issue is in
  MarketplaceClient or PluginManager.install_plugin delegation.
- If the issue is class_name collision: grep entire codebase for
  `class_name MarketplaceClient` and `class_name MarketplaceBrowseDialog`.

---

## 1. WHERE EVERYTHING LIVES

```
~/github/plugins-dcr1/                                    (worktree)
  branch: dcr/plugins-fcib-ci
  remote: lab → https://github.com/imrans-lab/minerva-plugins
  HEAD: a03e4f1 (registry v2 — per-target download URLs)
  Other recent commits:
    197405b — DCR1 W9 auto-tag (main=clean, branches=-branch- sentinel)
    1d8ed4a — DCR1 W4 registry generator + drift-check CI
    bd19c8a2 ad78ac42 are on the Minerva swarm branch (see below)

~/github/Minerva/                                          (primary)
  branch: user/imran/experiments/swarm
  remote: origin → https://github.com/turnrocklabs/Minerva
  HEAD pushed: bd19c8a2 (DCR3 Phase B Browse Marketplace UI)
  Other recent:
    ad78ac42 — DCR3 Phase A MarketplaceClient
    625bb3ef — pickup: scansort area shipped
```

ipeerbhai/plugins is the dead-end old plugins repo (billing-locked
personal account); ignore it.

---

## 2. WHAT'S DONE

### DCR 1 — Plugins FCIB + CI + Auto-tag
Docket: `019e62ad894d` (project=minerva). All 9 work units shipped:
- W0 smoke harness `scripts/smoke/mcp_smoke.py`
- W1-W3 per-plugin matrix workflows (`.github/workflows/{scansort,cad,presentation}.yml`)
- Cold-Opus Quality+DRY reviews
- W4 `scripts/regen_registry.py` + `.github/workflows/registry-check.yml`
- W5 tag-driven release publish via softprops/action-gh-release@v2
- W6 end-to-end real release validated for all 3 plugins
- W7 binary purge — N/A (binaries were already gitignored, audit was wrong)
- W8 per-plugin READMEs
- W9 auto-tag: main → clean version, branch → `-branch-<sanitized>` suffix,
  registry filter skips `-branch-` tags

6 live releases on imrans-lab/minerva-plugins:
- scansort-v0.0.0-pre, cad-v0.0.0-pre, presentation-v0.0.0-pre (manual)
- scansort-v0.0.1-branch-dcr-plugins-fcib-ci (auto, prerelease)
- cad-v0.1.0-branch-dcr-plugins-fcib-ci (auto, prerelease)
- presentation-v0.0.1-branch-dcr-plugins-fcib-ci (auto, prerelease)

### DCR 2 — Minerva Mac ARM64
Docket: `019e62adb39d`. **Verified by audit, no code change.**
- `Minerva-macOS-Build` artifact is 147MB on swarm-branch CI
- `src/export_presets.cfg:162` has `binary_format/architecture="universal"`
- `build.yml` lipo's the terminal/wry/cef extensions to universal
- HITL launch on actual Apple Silicon hardware still deferred

### DCR 3 — Marketplace
Docket: `019e62ade5be`. Phase A + Phase B both shipped.

**Phase A — MarketplaceClient (Node)**: `src/Scripts/Services/Plugins/MarketplaceClient.gd`
- `fetch_registry(url?)` — GETs registry.json
- `resolve_platform_target()` — returns linux-x86_64/linux-arm64/macos-universal/windows-x86_64
- `install_from_url(tarball_url, installer)` — downloads via HTTPRequest+set_download_file (streams to disk), `tar -xzf` extract, `HashingContext` SHA256 verify of every entry in SHA256SUMS, moves to user://plugins/<id>/, chmod +x entrypoint, delegates registration to `installer`
- `installer` is duck-typed:
    - null = stop after staging (tests)
    - PluginManager (has install_plugin) = full flow with cap-grant/skill-seed (production)
    - PluginDB (has install) = minimal store registration (legacy)
- `install_from_registry_entry(entry, installer)` — picks target URL from `entry.downloads`, calls install_from_url
- Headless test: `src/test/test_marketplace_install_from_url.gd` — 3/3 PASS
  (happy path against fixture HTTP server, 404, SHA mismatch)

**Phase B — Marketplace UI**: `src/Scripts/UI/Controls/PluginManagerPanel/MarketplaceBrowseDialog.gd`
- Window class with HSplitContainer: ItemList of plugins | RichTextLabel details
- Footer: status label, Install button, Close button
- Header: title + Refresh button
- Items unavailable for the user's platform are disabled with tooltip
- Already-installed plugins show "Already installed" instead of Install
- Install delegates to MarketplaceClient.install_from_registry_entry with
  `SingletonObject.plugin_manager` (full PluginManager.install_plugin path)
- Emits `plugin_installed(plugin_id)` signal

PluginManagerPanel.gd was edited to add:
- `_browse_button: Button` field
- "Browse Marketplace..." button in `_build_bottom_toolbar`
- `_on_browse_marketplace_pressed()` opens the dialog
- `_on_marketplace_install_complete(plugin_id)` refreshes the installed list

---

## 3. THE FAILING HITL

User triggered workflow_dispatch on `user/imran/experiments/swarm`, got
the CI build artifact, ran it, **Minerva does not run**. No error details
captured before compaction.

**First debug action on resume:** ask the user for the launch error
(stderr/stdout from running the Minerva binary directly from terminal).
If on Linux: `cd Minerva-Linux-Build && ./Minerva 2>&1 | head -40`.
If on macOS: `Minerva.app/Contents/MacOS/Minerva 2>&1 | head -40`.
If on Windows: `Minerva.exe 2>&1 | head -40`.

**While waiting for that, useful concurrent checks:**
- Confirm the CI build itself was green at
  https://github.com/turnrocklabs/Minerva/actions
- If green, was Minerva-{platform}-Build artifact non-zero size?
- Check the latest commit (bd19c8a2) was actually IN the build by
  examining a previous successful build vs this one

---

## 4. TEST GATE — last verified

- `test_marketplace_install_from_url.gd` 3/3 (happy, 404, bad-SHA) **local headless on swarm at bd19c8a2**
- Minerva headless boot with my code present: no SCRIPT ERROR (local check)
- All plugin CI workflows green on `dcr/plugins-fcib-ci` at a03e4f1
- 6 GitHub Releases on imrans-lab/minerva-plugins resolve (HEAD 200)

---

## 5. OPEN FOLLOW-UPS (work_items already filed)

| ID | Title | Status |
|---|---|---|
| `019e6358cf7a` | Extract pack+upload composite action | backlog |
| `019e634eae3f` | cad Windows port (worker.go syscall split) | **done in-cycle** |

Plus 3 deferred scansort follow-ups (`019e565b5b85`-style) from earlier DCRs.

---

## 6. AFTER MINERVA-WON'T-RUN IS FIXED

1. Verify the Browse Marketplace button appears in Plugin Manager
2. Open marketplace, see 3 plugins listed with platform availability
3. Install scansort from marketplace
4. Verify it appears in installed list + Plugin's panel works
5. THIS IS THE END-TO-END HITL — succeeding here means DCR 3 is shippable

After HITL passes, eventual promotion is `swarm → development → main`
per the Minerva release strategy (the user is NOT ready to merge to
main yet — keep on swarm).

---

## 7. HARD RULES (unchanged)

- Per-file `git add` only — never `-A` or `.`. No `--no-verify`.
- No `vendor/` touches.
- No force-push, no `git reset --hard`, no push without an explicit user ask.
- Never `cp` over a mapped binary — use `install -m 755` (atomic).
- pkill target is `godot`, not `Minerva`.
- Co-author trailer: `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- Use MCP for state probes, not filesystem reads.

---

## 8. KEY MEMORY LANDMARKS

- `MEMORY.md` index entries to read:
  - `project_active_marketplace_dcr3.md` — DCR 3 active state (see below)
  - `project_plugins_already_fcib_clean.md` — FCIB audit correction
- Durable hints saved during this work:
  - `019e63a3bcf4` — minerva-plugin-platform/canonical-install-is-pluginmanager-not-plugindb
  - `019e634e4a96` — go-cross-platform-plugins/syscall-kill-and-setpgid-are-unix-only
- Session nudges (promote any that recur):
  - `docket-mcp/no-unlink-tool`
  - `github-actions/billing-lock-symptom`
  - `github-actions/matrix-not-in-job-level-if`
  - `mcp-spec/server-identity-field-variants`
  - `scansort-process-pipeline/handle-process-run-offset-zero-bug` (older)
