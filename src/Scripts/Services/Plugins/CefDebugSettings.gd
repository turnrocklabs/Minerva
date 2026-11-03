class_name CefDebugSettings
extends RefCounted
## Startup-only host preference mapped to the existing native CEF CLI hook.
## Release builds opt in; gdcef's debug/editor policy is unchanged.

const SCOPE := "core:cef"
const CONFIG_SECTION := "CEF"
const DEFAULT_PORT := 9222
const SWITCH_KEY := "godot_cef/advanced/custom_command_line_switches"
const SCHEMA := {
	"config_section": CONFIG_SECTION,
	"tab": "Advanced",
	"section": "CEF remote debugging",
	"fields": [
		{
			"key": "cef_remote_debugging", "type": "bool", "default": false,
			"label": "CEF remote debugging",
			"help": "Allow local agents to inspect browser panels. Off in release builds by default; restart Minerva after changing. Debug/editor policy is unchanged.",
		},
		{
			"key": "cef_remote_debugging_port", "type": "number", "default": DEFAULT_PORT,
			"label": "CEF remote debugging port",
			"help": "Loopback port, whole number 1024–65535. Restart required. Invalid values leave the opt-in unapplied.",
		},
	],
}


static func configure(config_path: String) -> void:
	# The lifecycle pin initializes CEF before SingletonObject loads its normal
	# config. Read this one startup preference without changing that load order.
	var config := ConfigFile.new()
	var error := config.load(config_path)
	if error != OK:
		if error != ERR_FILE_NOT_FOUND:
			push_warning("[CEF] Remote debugging preference unreadable: %s" % error_string(error))
		return
	var enabled: Variant = config.get_value(CONFIG_SECTION, "cef_remote_debugging", false)
	if not (enabled is bool) or not enabled:
		return
	var value: Variant = config.get_value(CONFIG_SECTION, "cef_remote_debugging_port", DEFAULT_PORT)
	if not (value is int or value is float):
		push_warning("[CEF] Remote debugging opt-in ignored: port must be a whole number 1024–65535")
		return
	var number := float(value)
	if not is_finite(number) or number != floor(number) or number < 1024 or number > 65535:
		push_warning("[CEF] Remote debugging opt-in ignored: port must be a whole number 1024–65535")
		return
	var port := int(number)
	var switches: Array[String] = []
	for line in str(ProjectSettings.get_setting(SWITCH_KEY, "")).split("\n"):
		var key: String = line.strip_edges().trim_prefix("--").get_slice("=", 0)
		if key in ["remote-debugging-port", "remote-debugging-address", "remote-allow-origins"]:
			continue
		switches.append(line)
	switches.append("remote-debugging-port=%d" % port)
	switches.append("remote-allow-origins=http://127.0.0.1:%d" % port)
	ProjectSettings.set_setting(SWITCH_KEY, "\n".join(switches))
	print("[CEF] CEF remote debugging enabled on loopback port %d (startup preference)" % port)
