class_name BuiltinVoicePlugin
extends RefCounted
## Trusted host-owned identity and platform path for the bundled detector.

const ID := "voice"


static func target_triple() -> String:
	var architecture := Engine.get_architecture_name()
	match OS.get_name():
		"Windows": return "windows-x86_64" if architecture in ["x86_64", "amd64"] else ""
		"macOS":
			if architecture in ["arm64", "aarch64"]:
				return "macos-arm64"
			return "macos-amd64" if architecture in ["x86_64", "amd64"] else ""
		"Linux": return "linux-x86_64" if architecture in ["x86_64", "amd64"] else ""
		_: return ""


static func runtime_directory() -> String:
	var target := target_triple()
	if target.is_empty():
		return ""
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://plugins/voice/runtime-build/stage/%s" % target)
	var executable_dir := OS.get_executable_path().get_base_dir()
	if OS.get_name() == "macOS":
		return executable_dir.path_join("../Resources/builtin-plugins/voice").path_join(target).simplify_path()
	return executable_dir.path_join("builtin-plugins/voice")


static func definition():
	if runtime_directory().is_empty():
		return null
	var PluginDef = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var def = PluginDef.new()
	def.id = ID
	def.name = "Minerva Voice Detector"
	def.version = "0.1.0"
	def.transport = "stdio"
	def.data_directory = runtime_directory()
	def.entrypoint = "./python.exe" if OS.get_name() == "Windows" else "./bin/python3"
	def.args.assign(["-B", "-I", "-m", "minerva_voice_worker"])
	def.working_dir = def.data_directory
	def.network_mode = "localhost"
	def.autostart = false
	return def


static func is_reserved(plugin_id: String) -> bool:
	return plugin_id == ID
