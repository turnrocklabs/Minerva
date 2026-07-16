# Panel-Executed Tools — HITL Debt Register

Deferred human checks for DCR `019f6c3d0e3d` (panel-executed plugin MCP tools),
per work-cycle campaign mode (owner-authorized fully-autonomous run
2026-07-16: "work autonomously until ready for a large HITL at the end").
Rounds append; entries burn in ONE consolidated acceptance session at campaign
end. Every entry names the automated proxy that stood in for the human check —
no proxy, no deferral.

| # | Deferred check | Automated proxy in place | Source round |
|---|---|---|---|
| 1 | Live pcb plugin reinstall picks up the manifest `executor:"panel"` entries (manifest edits are not hot-reloaded — reinstall/rebuild required per contract §1c) and the plugin manager shows the tools | test_pcb_panel_tools_migration.gd 70/0 proves the dispatch contract headlessly via direct registry construction; test_plugin_definition.gd 109/0 validates the manifest shape | C2 |
| 2 | Agent-facing tool-parity spot-check through a REAL running Minerva + MCP client: minerva_pcb_pin_info / get_components / add_component answer identically to pre-migration | test_pcb_pin_inspector.gd 45/0 dispatches pin_info through the real PluginToolRegistry; test_pcb_panel_tools.gd 87/0 covers the wave-1 surface shape-for-shape | C2 |
