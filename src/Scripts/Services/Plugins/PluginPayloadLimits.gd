class_name PluginPayloadLimits
extends RefCounted
## Bounds on serialized plugin IPC dictionaries, measured in UTF-8 bytes.

const CONTROL_BYTES := 64 * 1024
const ROUTING_BYTES := 4096
const BULK_BYTES := 8 * 1024 * 1024


static func size_bytes(payload: Dictionary) -> int:
	return JSON.stringify(payload).to_utf8_buffer().size()


## Return a bounded error without changing the caller's dictionary.
static func check(payload: Dictionary, plugin_id: String = "", limit: int = CONTROL_BYTES) -> Dictionary:
	var actual := size_bytes(payload)
	return PluginErrors.payload_too_large(plugin_id.left(256), limit, actual) if actual > limit else {}


static func bound_reply(payload: Dictionary, plugin_id: String = "", limit: int = CONTROL_BYTES) -> Dictionary:
	var error := check(payload, plugin_id, limit)
	return payload if error.is_empty() else error


## Document transfer channels already carry complete state, outside control IPC.
static func scene_push_limit(channel: String) -> int:
	return BULK_BYTES if channel in ["attach_buffer", "text_changed", "host_owned_save.set_request"] else CONTROL_BYTES
