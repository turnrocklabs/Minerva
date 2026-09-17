# agent-relay plugin

Minerva plugin for relaying messages to and from CLI agent processes running in
terminal tabs. Watches terminals for turn completion, cleans TUI chrome from
output, and (B4) distils agent turns via host.providers.chat.

## GDScript class name prefix

For any future GDScript files in this plugin, the `class_name` MUST start with
`Agentrelay_` (PluginDefinition.canonical_prefix: strip underscores from the
manifest id "agent_relay" → "agentrelay", upper-case the first char only →
"Agentrelay"). Install will fail with `class_name_bad_prefix` otherwise.
Note the manifest id is `agent_relay` (underscores — ids must be lowercase
alphanumeric+underscore); only the DIRECTORY is named agent-relay.

No UI panels are included in v1 (B1 scaffold).

## Phase plan

- **B1** (this): Scaffold — manifest, Rust worker, tool surface + chrome filter
- **B2**: Terminal substrate — live reads via host.terminal.*, bell detection
- **B3**: Per-CLI turn-detection profiles — spinner stripping, prompt-box regex
- **B4**: Distil + deliver — read_turn via host.providers.chat, note delivery
- **B5**: Tests / HITL
- **B6**: Marketplace packaging (regen_registry.py PLUGIN_DIRS allow-list)

## Build

```bash
scripts/build-extensions.sh --agent-relay-only
# Windows: scripts\build-extensions.ps1 -AgentRelayOnly
```

The source-built release binary and package are gitignored (FCIB policy). The
host selects the staged binary for its platform. It also passes `--state-file`
under Minerva's writable user data so packaged runtimes never write beside the
executable; standalone launches retain `AGENT_RELAY_STATE_FILE` and the
executable-adjacent fallback.

## Tool prefix rule

All tools are prefixed `minerva_agent_relay_*`. This is enforced at manifest
validation (PluginDefinition.gd:322) and at runtime dispatch (PluginPolicy.gd:320).

## Declared event

`agent_relay.turn_completed` — payload:
```json
{
  "terminal_id": "string",
  "kind": "turn_completed|input_requested|agent_exited|terminal_closed|timed_out",
  "detection": "bell|settle_prompt|prompt_marker|child_exit|timeout"
}
```

The PluginEventBroker validates against the persisted plugins.json record.
If you see "undeclared event" warnings, reinstall the plugin to clear the
stale record.
