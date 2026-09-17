class_name InternalAgentRelayPlugin
extends RefCounted
## Trusted host-owned identity and platform path for the bundled Agent Relay.
##
## The manifest under src/plugins/agent-relay is the source of truth for the
## identity, the 15 minerva_agent_relay_* tools, the declared capabilities and
## the seeded relay skill. Only the backend paths are overridden here, because
## the runnable artifact is the staged Rust build, not the source checkout.

const ID := "agent_relay"
const MANIFEST_PATH := "res://plugins/agent-relay/manifest.json"
const SOURCE_STAGE := "res://plugins/agent-relay/runtime-build/stage"
const BINARY_NAME := "agent-relay-plugin"


static func binary_name() -> String:
	return "%s.exe" % BINARY_NAME if OS.get_name() == "Windows" else BINARY_NAME


static func runtime_directory() -> String:
	return InternalPlugins.staged_runtime_directory(ID, SOURCE_STAGE)


static func runtime_label() -> String:
	return "Agent Relay runtime"


static func required_runtime_files() -> Array[String]:
	return [binary_name(), "target-triple.txt"]


static func repair_hint() -> String:
	if OS.has_feature("editor"):
		return ("Run `powershell -ExecutionPolicy Bypass -File scripts\\build-extensions.ps1 -AgentRelayOnly`"
			if OS.get_name() == "Windows"
			else "Run `scripts/build-extensions.sh --agent-relay-only`")
	return "Reinstall the Minerva build for %s" % InternalPlugins.target_triple()


## Cheap runtime-facing guard, mirroring the built-in Voice contract: the
## staged directory must hold the worker binary and record the build target.
static func runtime_issue() -> String:
	var target := InternalPlugins.target_triple()
	var directory := runtime_directory()
	if target.is_empty() or directory.is_empty():
		return "Agent Relay is unavailable on this platform"
	return InternalPlugins.runtime_issue_for(
		runtime_label(), directory, target, required_runtime_files(), repair_hint())


static func definition():
	var directory := runtime_directory()
	if directory.is_empty():
		return null
	var PluginDef = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var def = PluginDef.from_manifest(MANIFEST_PATH)
	if def == null:
		return null
	# from_manifest points the backend at the manifest's own directory; the
	# worker actually lives in the staged build. Keep mutable state in Minerva's
	# writable user data rather than beside the packaged executable.
	def.data_directory = directory
	def.working_dir = directory
	def.entrypoint = "./%s" % binary_name()
	var state_file := ProjectSettings.globalize_path(
		"user://plugins/data".path_join(ID).path_join("agent_relay_state.json"))
	# Preserve state written by the former user-installed relay location. Fresh
	# built-in installs use the normal host-managed plugin data directory.
	var legacy_state_file := ProjectSettings.globalize_path(
		"user://plugins".path_join(ID).path_join("agent_relay_state.json"))
	if FileAccess.file_exists(legacy_state_file):
		state_file = legacy_state_file
	def.args.assign(["--state-file", state_file])
	def.autostart = false
	def.auto_reload = false
	return def
