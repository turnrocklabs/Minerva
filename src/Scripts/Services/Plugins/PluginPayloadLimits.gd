class_name PluginPayloadLimits
extends RefCounted
## Bounds on serialized plugin IPC dictionaries, measured in UTF-8 bytes.

const CONTROL_BYTES := 64 * 1024
const BULK_BYTES := 8 * 1024 * 1024


static func size_bytes(payload: Dictionary) -> int:
	return JSON.stringify(payload).to_utf8_buffer().size()
