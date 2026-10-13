class_name PluginArtifactPath
extends RefCounted
## Shared cross-platform artifact lookup for setup, verification and launch.

static func resolve(path: String, platform: String = "") -> String:
	if FileAccess.file_exists(path) or FileAccess.file_exists(ProjectSettings.localize_path(path)) or DirAccess.dir_exists_absolute(path):
		return path
	var windows: bool = (OS.get_name() if platform.is_empty() else platform) == "Windows"
	if windows and (FileAccess.file_exists(path + ".exe") or FileAccess.file_exists(ProjectSettings.localize_path(path + ".exe"))):
		return path + ".exe"
	return ""
