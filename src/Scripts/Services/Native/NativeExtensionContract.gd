class_name NativeExtensionContract
extends RefCounted
## Editor runs can load an old native binary after updating source.

static func warning() -> String:
	if not OS.has_feature("editor"):
		return ""
	var missing: PackedStringArray = []
	for method: String in ["try_lock_status", "try_lock", "unlock", "is_locked", "replace_file"]:
		if not ClassDB.class_has_method("ProcessFileLock", method):
			missing.append("ProcessFileLock." + method)
	if not ClassDB.class_has_method("SubProcess", "stop_gracefully"):
		missing.append("SubProcess.stop_gracefully")
	if missing.is_empty():
		return ""
	var platform: String = OS.get_name()
	var library: String = "libterminal.macos.template_debug.framework"
	var command: String = "scripts/build-extensions.sh macos --terminal-only"
	if platform == "Linux":
		library = "libterminal.linux.template_debug.x86_64.so"
		command = "scripts/build-extensions.sh linux --terminal-only"
	elif platform == "Windows":
		library = "libterminal.windows.template_debug.x86_64.dll"
		command = "powershell -ExecutionPolicy Bypass -File scripts/build-extensions.ps1"
	return "Stale or missing native extension res://bin/%s: missing %s. Rebuild from the repository root: %s" % [library, ", ".join(missing), command]
