extends RefCounted
## Optimistic-concurrency check for buffered document writes (DCR 019ea404ffcd P3).
##
## Pure + dependency-free (no SingletonObject/Editor refs) so it compiles and is
## unit-testable headless. Used by MCPDocTools to reject a write when the buffer
## moved since the caller read its version — DocumentBuffer.apply_edit is
## whole-buffer last-write-wins, so without this a human edit landing between an
## agent's read and its write would be silently clobbered.
##
## Preloaded (not class_name) so headless `--script` tests resolve it without the
## global_script_class_cache dance.

## Returns {} to PROCEED, or a version_mismatch envelope to return to the caller
## as-is. JSON numbers arrive as float in GDScript, so the incoming value is int()'d.
static func check(args: Dictionary, current_version: int, path: String = "") -> Dictionary:
	if not args.has("if_match_version"):
		return {}
	var want := int(args.get("if_match_version"))
	if current_version != want:
		# `error` carries the want/got detail because the capability broker
		# forwards only result.error to plugins (CapabilityBroker._handle_mcp_proxy)
		# — dropping the structured fields. `code` is the stable handle for tests
		# and programmatic matching.
		return {
			"success": false,
			"ok": false,
			"code": "version_mismatch",
			"error": "version_mismatch (want %d, got %d) — re-read with minerva_doc_read and retry" % [want, current_version],
			"want": want,
			"got": current_version,
			"path": path,
		}
	return {}
