class_name PluginChatProviderRegistry
extends RefCounted
## Runtime registry of plugin-supplied chat-provider entries (chat-passthrough W1).
##
## Plugins register provider entries via the host.chat_providers.register
## capability (routed through CapabilityBroker). Each entry advertises a
## generate_tool the plugin exposes; selecting the entry in a chat gives that
## chat a PluginProvider whose generate_content dispatches to the plugin.
##
## Lifecycle: subscribe a PluginManager's plugin_stopped + plugin_crashed
## signals to drop_plugin() so entries vanish gracefully when the backing
## plugin disappears. The chooser listens to chat_providers_changed to
## repopulate.
##
## Entry key format: "plugin:<plugin_id>:<entry_id>". The key is stable across
## re-registration of the same (plugin_id, entry_id) pair (idempotent update),
## so a serialized chat can re-resolve its provider after restart.
##
## RefCounted (not Node) so it can be constructed in isolation for headless
## tests; it never needs the scene tree.

## Emitted whenever the set of entries changes (register / update / unregister /
## plugin drop). The chooser subscribes and repopulates.
signal chat_providers_changed()

## History-mode values an entry may declare.
const HISTORY_MODE_NEWEST_ONLY := "newest_only"
const HISTORY_MODE_FULL := "full"
const _VALID_HISTORY_MODES := [HISTORY_MODE_NEWEST_ONLY, HISTORY_MODE_FULL]

## Default per-call timeout (seconds) when an entry does not declare one.
const DEFAULT_TIMEOUT_SEC := 600

## key:String ("plugin:<plugin_id>:<entry_id>") -> entry:Dictionary
var _entries: Dictionary = {}


## Build the canonical registry key for a (plugin_id, entry_id) pair.
static func make_key(plugin_id: String, entry_id: String) -> String:
	return "plugin:%s:%s" % [plugin_id, entry_id]


## Register (or idempotently update) a chat-provider entry for a plugin.
##
## `dict` fields (as delivered by the broker):
##   entry_id: String (required)        — plugin-unique entry identifier
##   display_name: String (required)    — shown in the provider chooser
##   generate_tool: String (required)   — plugin tool name to dispatch a turn
##   history_mode: "newest_only"|"full" (required)
##   timeout_sec: int (optional, default DEFAULT_TIMEOUT_SEC)
##   cancel_tool: String (optional)     — plugin tool to abandon an in-flight turn
##   metadata: Dictionary (optional)    — opaque provider-specific extras
##
## Returns the stored entry Dictionary on success, or {} when the dict is
## structurally invalid (caller — the broker — validates first and surfaces a
## schema error, so {} here is a defensive belt-and-braces guard).
##
## Re-registering the same (plugin_id, entry_id) replaces the prior entry in
## place — same key, no duplicate. Emits chat_providers_changed either way.
func register_entry(plugin_id: String, dict: Dictionary) -> Dictionary:
	if plugin_id.is_empty():
		return {}
	var entry_id: String = str(dict.get("entry_id", "")).strip_edges()
	var display_name: String = str(dict.get("display_name", "")).strip_edges()
	var generate_tool: String = str(dict.get("generate_tool", "")).strip_edges()
	var history_mode: String = str(dict.get("history_mode", "")).strip_edges()
	if entry_id.is_empty() or display_name.is_empty() or generate_tool.is_empty():
		return {}
	if history_mode not in _VALID_HISTORY_MODES:
		return {}

	# JSON ints arrive as floats through the MCP channel; coerce defensively.
	var timeout_sec: int = DEFAULT_TIMEOUT_SEC
	if dict.has("timeout_sec") and dict["timeout_sec"] != null:
		timeout_sec = int(dict["timeout_sec"])
		if timeout_sec <= 0:
			timeout_sec = DEFAULT_TIMEOUT_SEC

	var cancel_tool: String = str(dict.get("cancel_tool", "")).strip_edges()

	var metadata: Dictionary = {}
	if dict.has("metadata") and dict["metadata"] is Dictionary:
		metadata = (dict["metadata"] as Dictionary).duplicate(true)

	var key: String = make_key(plugin_id, entry_id)
	var entry: Dictionary = {
		"key": key,
		"plugin_id": plugin_id,
		"entry_id": entry_id,
		"display_name": display_name,
		"generate_tool": generate_tool,
		"history_mode": history_mode,
		"timeout_sec": timeout_sec,
		"cancel_tool": cancel_tool,
		"metadata": metadata,
	}
	_entries[key] = entry
	chat_providers_changed.emit()
	return entry.duplicate(true)


## Remove a single entry. Returns true if an entry was removed.
func unregister_entry(plugin_id: String, entry_id: String) -> bool:
	var key: String = make_key(plugin_id, entry_id)
	if not _entries.has(key):
		return false
	_entries.erase(key)
	chat_providers_changed.emit()
	return true


## Drop every entry owned by a plugin. Wired to plugin_stopped /
## plugin_crashed. Emits chat_providers_changed once if anything was removed.
func drop_plugin(plugin_id: String) -> int:
	var to_remove: Array = []
	for key in _entries.keys():
		if (_entries[key] as Dictionary).get("plugin_id", "") == plugin_id:
			to_remove.append(key)
	for key in to_remove:
		_entries.erase(key)
	if not to_remove.is_empty():
		chat_providers_changed.emit()
	return to_remove.size()


## Return a defensive copy of all entries (order is insertion order).
func list_entries() -> Array:
	var out: Array = []
	for key in _entries.keys():
		out.append((_entries[key] as Dictionary).duplicate(true))
	return out


## Look up one entry by its canonical key. Returns {} when absent.
func get_entry(key: String) -> Dictionary:
	if not _entries.has(key):
		return {}
	return (_entries[key] as Dictionary).duplicate(true)


## Whether an entry with the given key currently exists.
func has_entry(key: String) -> bool:
	return _entries.has(key)
