class_name InternalPlugins
extends RefCounted
## Registry of host-owned plugins that ship inside the Minerva tree.
##
## Membership is code, never a manifest claim: only the ids listed in REGISTRY
## are reserved. Reserved ids are rebuilt from their trusted res:// source on
## every startup, are never written to user://plugins/plugins.json, and refuse
## install, update, removal and lifecycle-flag changes.
##
## Each entry names a provider script exposing these statics:
##   definition()             -> PluginDefinition or null when unsupported here
##   runtime_directory()      -> String, absolute path of the runnable artifact
##   runtime_label()          -> String, how the runtime is named to the user
##   required_runtime_files() -> Array[String], paths relative to that directory
##   runtime_issue()          -> String, empty when the runtime is usable
##   repair_hint()            -> String, the command that repairs the runtime
## The issue string is shown verbatim to the user, so every member owns an
## actionable repair sentence.

const REGISTRY: Array[Dictionary] = [
	{
		"id": "voice",
		"provider": "res://Scripts/Services/Voice/BuiltinVoicePlugin.gd",
	},
	{
		"id": "agent_relay",
		"provider": "res://Scripts/Services/Plugins/InternalAgentRelayPlugin.gd",
	},
]


## True when `plugin_id` names a host-owned plugin.
static func has(plugin_id: String) -> bool:
	for entry in REGISTRY:
		if entry["id"] == plugin_id:
			return true
	return false


## Every host-owned id, in registration order.
static func ids() -> Array[String]:
	var out: Array[String] = []
	for entry in REGISTRY:
		out.append(entry["id"])
	return out


## Load the provider script for `plugin_id`, or null when it is not a member.
static func provider_for(plugin_id: String):
	for entry in REGISTRY:
		if entry["id"] == plugin_id:
			return load(entry["provider"])
	return null


## Rebuild a member's definition from its trusted source. Null when the member
## is unknown or unsupported on this platform.
static func definition_for(plugin_id: String):
	var provider = provider_for(plugin_id)
	return null if provider == null else provider.definition()


## Empty when the member's runtime is usable, otherwise a user-facing sentence
## naming what is missing and how to repair it. Unknown ids report no issue so
## ordinary plugins keep their existing start path.
static func runtime_issue(plugin_id: String) -> String:
	var provider = provider_for(plugin_id)
	return "" if provider == null else str(provider.runtime_issue())


## The build/reinstall command that repairs a member's runtime.
static func repair_hint(plugin_id: String) -> String:
	var provider = provider_for(plugin_id)
	return "" if provider == null else str(provider.repair_hint())


## Run a member's runtime check against an arbitrary directory and target.
## Lets a suite build and damage a fixture stage without touching a real build.
static func runtime_issue_at(plugin_id: String, directory: String, target: String) -> String:
	var provider = provider_for(plugin_id)
	if provider == null:
		return ""
	return runtime_issue_for(
		str(provider.runtime_label()), directory, target,
		provider.required_runtime_files(), str(provider.repair_hint()))


## The files a member's staged runtime directory must contain on this host.
static func required_runtime_files(plugin_id: String) -> Array:
	var provider = provider_for(plugin_id)
	return [] if provider == null else provider.required_runtime_files()


# ---------------------------------------------------------------------------
# Shared platform helpers
# ---------------------------------------------------------------------------

## Platform triple naming the per-target artifact directory. Empty on a
## platform Minerva ships no internal-plugin runtime for.
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


## Resolve a member's runtime directory. Editor builds read the per-target
## staging directory the build-extensions script writes under `source_stage`;
## packaged builds read builtin-plugins/<id> next to the executable, which is
## where the release workflow copies that same stage.
static func staged_runtime_directory(plugin_id: String, source_stage: String) -> String:
	var target := target_triple()
	if target.is_empty():
		return ""
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path(source_stage.path_join(target))
	var executable_dir := OS.get_executable_path().get_base_dir()
	if OS.get_name() == "macOS":
		return executable_dir.path_join(
			"../Resources/builtin-plugins/%s" % plugin_id).path_join(target).simplify_path()
	return executable_dir.path_join("builtin-plugins/%s" % plugin_id)


## Shared cheap runtime guard: report the first reason `directory` cannot serve
## as `label`'s runtime. `required_relative` lists the files the stage must
## contain, one of which must be target-triple.txt recording the build target.
## Empty return means usable; anything else is shown to the user verbatim.
static func runtime_issue_for(
	label: String, directory: String, target: String,
	required_relative: Array, repair: String
) -> String:
	var missing: Array[String] = []
	for relative in required_relative:
		if not FileAccess.file_exists(directory.path_join(str(relative))):
			missing.append(str(relative).get_file())
	if not missing.is_empty():
		return "%s is missing %s. %s." % [label, ", ".join(missing), repair]
	var recorded_target := FileAccess.get_file_as_string(
		directory.path_join("target-triple.txt")).strip_edges()
	if recorded_target != target:
		return "%s targets %s, but this host requires %s. %s." % [
			label, recorded_target, target, repair]
	return ""
