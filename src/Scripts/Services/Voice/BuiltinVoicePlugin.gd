class_name BuiltinVoicePlugin
extends RefCounted
## Trusted host-owned identity and platform path for the bundled detector.

const ID := "voice"
const SOURCE_STAGE := "res://plugins/voice/runtime-build/stage"


static func target_triple() -> String:
	return InternalPlugins.target_triple()


static func runtime_directory() -> String:
	return InternalPlugins.staged_runtime_directory(ID, SOURCE_STAGE)


static func repair_hint() -> String:
	if OS.has_feature("editor"):
		return ("Run `powershell -ExecutionPolicy Bypass -File scripts\\build-extensions.ps1 -VoiceOnly`"
			if OS.get_name() == "Windows"
			else "Run `scripts/build-extensions.sh --voice-only`")
	return "Reinstall the Minerva build for %s" % target_triple()


## Cheap runtime-facing guard. Contributor readiness performs the deeper
## manifest, freshness, architecture, and MCP handshake validation.
static func runtime_issue() -> String:
	var target := target_triple()
	var directory := runtime_directory()
	if target.is_empty() or directory.is_empty():
		return "Voice Support is unavailable on this platform"
	return runtime_issue_for(directory, target, repair_hint(), OS.get_name() == "Windows")


static func runtime_label() -> String:
	return "Voice runtime"


static func required_runtime_files() -> Array[String]:
	return required_runtime_files_for(OS.get_name() == "Windows")


## `windows_runtime` selects the interpreter layout the bundle was built with,
## which is not always this host's (the suite checks both from one platform).
static func required_runtime_files_for(windows_runtime: bool) -> Array[String]:
	return [
		"manifest.sha256",
		"input-artifacts.sha256",
		"source-inputs.sha256",
		"target-triple.txt",
		"python.exe" if windows_runtime else "bin/python3",
	]


static func runtime_issue_for(
	directory: String, target: String, repair: String, windows_runtime: bool
) -> String:
	return InternalPlugins.runtime_issue_for(
		runtime_label(), directory, target,
		required_runtime_files_for(windows_runtime), repair)


static func definition():
	if runtime_directory().is_empty():
		return null
	var PluginDef = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var def = PluginDef.new()
	def.id = ID
	def.name = "Voice Support"
	def.version = "0.1.0"
	def.transport = "stdio"
	def.data_directory = runtime_directory()
	def.entrypoint = "./python.exe" if OS.get_name() == "Windows" else "./bin/python3"
	def.args.assign(["-B", "-I", "-m", "minerva_voice_worker"])
	def.working_dir = def.data_directory
	def.network_mode = "localhost"
	def.autostart = false
	return def
