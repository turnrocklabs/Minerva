extends SceneTree
## Unit tests for plugin capability declaration + install-time validation.
##
## Covers DCR-1 grandchild 019dc5d4f6877ae5be60ea02e51dcd38:
##   - Manifest 'capabilities' parsing (allowed values, rejection of typos)
##   - PluginDefinition.validate_capabilities() per-capability requirement contract
##   - PluginDB.install() rejection path with structured _last_install_error
##   - to_dict / from_dict round-trip preserves the capabilities array
##
## Run: godot --headless --path src --script test/test_plugin_capabilities.gd

const PluginDefinition_ = preload("res://Scripts/Services/Plugins/PluginDefinition.gd")
const PluginDB_ = preload("res://Scripts/Services/Plugins/PluginDB.gd")

var _pass_count: int = 0
var _fail_count: int = 0
var _tmp_root: String = ""


# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

func _initialize() -> void:
	_tmp_root = OS.get_user_data_dir().path_join("test_plugin_capabilities_%d" % Time.get_ticks_msec())
	DirAccess.make_dir_recursive_absolute(_tmp_root)

	test_parse_allowed_capabilities()
	test_parse_rejects_unknown_capability()
	test_parse_rejects_non_array()
	test_parse_dedupes_duplicates()
	test_to_dict_omits_when_empty()
	test_to_from_dict_round_trip()

	test_validate_project_state_pass()
	test_validate_project_state_missing_channel()
	test_validate_project_state_missing_save_hook()
	test_validate_project_state_missing_load_hook()

	test_validate_host_owned_save_pass()
	test_validate_host_owned_save_missing_extensions()
	test_validate_host_owned_save_missing_save_mode()
	test_validate_host_owned_save_missing_hook()

	test_validate_project_export_pass()
	test_validate_project_export_missing_channels()

	test_validate_no_capabilities_passes()
	test_validate_multiple_capabilities()

	test_pluginddb_install_blocks_on_capability_error()
	test_plugindb_install_succeeds_when_capabilities_satisfied()

	test_validate_files_path_empty_input()
	test_validate_files_path_in_scope()
	test_validate_files_path_out_of_scope()
	test_validate_files_path_traversal_normalized_then_rejected()
	test_validate_files_path_user_prefix_expanded()
	test_validate_files_path_empty_allowlist_rejects()
	test_validate_files_path_relative_rejected()
	test_validate_files_path_dotdot_segment_rejected()
	test_validate_files_path_prefix_substring_rejected()
	test_validate_files_path_exact_match_accepted()
	test_validate_files_path_subdir_accepted()

	# Cleanup
	_remove_dir_recursive(_tmp_root)

	print("\n=== test_plugin_capabilities ===")
	print("PASS: %d" % _pass_count)
	print("FAIL: %d" % _fail_count)
	if _fail_count > 0:
		quit(1)
	else:
		quit(0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass_count += 1
	else:
		_fail_count += 1
		print("FAIL: %s — %s" % [label, detail])


func _remove_dir_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full: String = path.path_join(entry)
			if dir.current_is_dir():
				_remove_dir_recursive(full)
			else:
				DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------

## Build a minimal manifest Dictionary with optional caller-supplied additions.
## Caller may override or extend any field, including ui.panels and ipc_messages.
func _make_manifest(overrides: Dictionary = {}) -> Dictionary:
	var base: Dictionary = {
		"id": "captest",
		"name": "Cap Test",
		"version": "0.1.0",
		"backend": {
			"transport": "stdio",
			"entrypoint": "echo",
		},
		"ui": {
			"panels": [
				{
					"name": "main",
					"kind": "godot_scene",
					"entry_scene": "ui/Panel.tscn",
					"scripts": ["ui/Panel.gd"],
				},
			],
			"ipc_messages": [],
		},
	}
	for key in overrides:
		base[key] = overrides[key]
	return base


## Write a temp panel script with optional method declarations.
## methods: Array of bare names (e.g. ["_on_panel_save_request", "_on_panel_load_request"]).
## Returns the data_directory absolute path that hosts ui/Panel.gd.
func _make_plugin_dir(methods: Array, slug: String = "") -> String:
	var subdir: String = slug if not slug.is_empty() else "p_%d" % Time.get_ticks_usec()
	var data_dir: String = _tmp_root.path_join(subdir)
	DirAccess.make_dir_recursive_absolute(data_dir.path_join("ui"))

	# Intentionally NO class_name — tests in this file only exercise capability
	# validation, and a class_name would force every plugin id used here to
	# match the canonical prefix (Captestblock_*, Captestpass_*, etc.).  Skipping
	# it keeps the fixture portable across plugin ids.
	var lines: Array[String] = [
		"extends Control",
		"",
	]
	for m in methods:
		lines.append("func %s(_arg = null) -> void:" % str(m))
		lines.append("\tpass")
		lines.append("")
	var script_path: String = data_dir.path_join("ui/Panel.gd")
	var f := FileAccess.open(script_path, FileAccess.WRITE)
	f.store_string("\n".join(lines))
	f.close()
	return data_dir


# ---------------------------------------------------------------------------
# Parser tests
# ---------------------------------------------------------------------------

func test_parse_allowed_capabilities() -> void:
	var manifest := _make_manifest({
		"capabilities": ["project_state", "host_owned_save", "project_export"],
		"ui": {
			"panels": [{"name": "main", "kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn", "scripts": ["ui/Panel.gd"]}],
			"ipc_messages": ["x.serialize", "x.deserialize", "x.collect", "x.apply"],
		},
		"project_file": {"serialize_channel": "x.serialize", "deserialize_channel": "x.deserialize"},
		"project_export": {"collect_channel": "x.collect", "apply_channel": "x.apply"},
	})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	_check("allowed capabilities parse", def != null and def.capabilities.size() == 3,
		"def=%s" % str(def))
	if def != null:
		_check("project_state present", "project_state" in def.capabilities)
		_check("host_owned_save present", "host_owned_save" in def.capabilities)
		_check("project_export present", "project_export" in def.capabilities)


func test_parse_rejects_unknown_capability() -> void:
	var manifest := _make_manifest({"capabilities": ["project_state", "totally_made_up"]})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	_check("unknown capability rejected", def == null,
		"expected null, got %s" % str(def))


func test_parse_rejects_non_array() -> void:
	var manifest := _make_manifest({"capabilities": "project_state"})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	_check("non-array capabilities rejected", def == null,
		"expected null, got %s" % str(def))


func test_parse_dedupes_duplicates() -> void:
	var manifest := _make_manifest({
		"capabilities": ["project_state", "project_state"],
		"ui": {
			"panels": [{"name": "main", "kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn", "scripts": ["ui/Panel.gd"]}],
			"ipc_messages": ["x.s", "x.d"],
		},
		"project_file": {"serialize_channel": "x.s", "deserialize_channel": "x.d"},
	})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	_check("duplicates deduped", def != null and def.capabilities.size() == 1,
		"size=%d" % (def.capabilities.size() if def != null else -1))


func test_to_dict_omits_when_empty() -> void:
	var manifest := _make_manifest({})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	var d: Dictionary = def.to_dict()
	_check("to_dict omits empty capabilities", not d.has("capabilities"),
		"unexpected key: %s" % str(d.keys()))


func test_to_from_dict_round_trip() -> void:
	var manifest := _make_manifest({
		"capabilities": ["project_state"],
		"ui": {
			"panels": [{"name": "main", "kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn", "scripts": ["ui/Panel.gd"]}],
			"ipc_messages": ["x.s", "x.d"],
		},
		"project_file": {"serialize_channel": "x.s", "deserialize_channel": "x.d"},
	})
	var def1: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	var d: Dictionary = def1.to_dict()
	var def2: PluginDefinition = PluginDefinition_.from_dict(d)
	_check("round-trip preserves capabilities",
		def2 != null and def2.capabilities.size() == 1 \
			and def2.capabilities[0] == "project_state",
		"got: %s" % (str(def2.capabilities) if def2 != null else "<null>"))


# ---------------------------------------------------------------------------
# validate_capabilities() — project_state
# ---------------------------------------------------------------------------

func test_validate_project_state_pass() -> void:
	var data_dir: String = _make_plugin_dir(
		["_on_panel_save_request", "_on_panel_load_request"], "ps_pass")
	var manifest := _make_manifest({
		"capabilities": ["project_state"],
		"ui": {
			"panels": [{"name": "main", "kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn", "scripts": ["ui/Panel.gd"]}],
			"ipc_messages": ["x.s", "x.d"],
		},
		"project_file": {"serialize_channel": "x.s", "deserialize_channel": "x.d"},
	})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	def.data_directory = data_dir
	var err: Dictionary = def.validate_capabilities()
	_check("project_state happy path passes", err.is_empty(), "got error: %s" % str(err))


func test_validate_project_state_missing_channel() -> void:
	var data_dir: String = _make_plugin_dir(
		["_on_panel_save_request", "_on_panel_load_request"], "ps_chan")
	var manifest := _make_manifest({"capabilities": ["project_state"]})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	def.data_directory = data_dir
	var err: Dictionary = def.validate_capabilities()
	_check("missing channel detected",
		err.get("error", "") == "capability_missing_channels",
		"got: %s" % str(err))


func test_validate_project_state_missing_save_hook() -> void:
	var data_dir: String = _make_plugin_dir(
		["_on_panel_load_request"], "ps_nosave")
	var manifest := _make_manifest({
		"capabilities": ["project_state"],
		"ui": {
			"panels": [{"name": "main", "kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn", "scripts": ["ui/Panel.gd"]}],
			"ipc_messages": ["x.s", "x.d"],
		},
		"project_file": {"serialize_channel": "x.s", "deserialize_channel": "x.d"},
	})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	def.data_directory = data_dir
	var err: Dictionary = def.validate_capabilities()
	_check("missing _on_panel_save_request detected",
		err.get("error", "") == "capability_missing_hook" \
			and err.get("detail", {}).get("missing_hook", "") == "_on_panel_save_request",
		"got: %s" % str(err))


func test_validate_project_state_missing_load_hook() -> void:
	var data_dir: String = _make_plugin_dir(
		["_on_panel_save_request"], "ps_noload")
	var manifest := _make_manifest({
		"capabilities": ["project_state"],
		"ui": {
			"panels": [{"name": "main", "kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn", "scripts": ["ui/Panel.gd"]}],
			"ipc_messages": ["x.s", "x.d"],
		},
		"project_file": {"serialize_channel": "x.s", "deserialize_channel": "x.d"},
	})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	def.data_directory = data_dir
	var err: Dictionary = def.validate_capabilities()
	_check("missing _on_panel_load_request detected",
		err.get("error", "") == "capability_missing_hook" \
			and err.get("detail", {}).get("missing_hook", "") == "_on_panel_load_request",
		"got: %s" % str(err))


# ---------------------------------------------------------------------------
# validate_capabilities() — host_owned_save
# ---------------------------------------------------------------------------

func test_validate_host_owned_save_pass() -> void:
	var data_dir: String = _make_plugin_dir(
		["_on_panel_save_request", "_on_panel_load_request"], "ho_pass")
	var manifest := _make_manifest({
		"capabilities": ["host_owned_save"],
		"ui": {
			"panels": [{
				"name": "main",
				"kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn",
				"scripts": ["ui/Panel.gd"],
				"file_extensions": [".captest"],
				"save_mode": "host_owned",
			}],
			"ipc_messages": [],
		},
	})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	def.data_directory = data_dir
	var err: Dictionary = def.validate_capabilities()
	_check("host_owned_save happy path passes", err.is_empty(), "got: %s" % str(err))


func test_validate_host_owned_save_missing_extensions() -> void:
	var data_dir: String = _make_plugin_dir(
		["_on_panel_save_request", "_on_panel_load_request"], "ho_noext")
	var manifest := _make_manifest({
		"capabilities": ["host_owned_save"],
		"ui": {
			"panels": [{
				"name": "main",
				"kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn",
				"scripts": ["ui/Panel.gd"],
				"save_mode": "host_owned",
			}],
			"ipc_messages": [],
		},
	})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	def.data_directory = data_dir
	var err: Dictionary = def.validate_capabilities()
	_check("missing file_extensions detected",
		err.get("error", "") == "capability_missing_file_extensions",
		"got: %s" % str(err))


func test_validate_host_owned_save_missing_save_mode() -> void:
	# Default save_mode is host_owned, so explicitly use plugin_owned to
	# verify the validator catches it.
	var data_dir: String = _make_plugin_dir(
		["_on_panel_save_request", "_on_panel_load_request"], "ho_plugin")
	var manifest := _make_manifest({
		"capabilities": ["host_owned_save"],
		"ui": {
			"panels": [{
				"name": "main",
				"kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn",
				"scripts": ["ui/Panel.gd"],
				"file_extensions": [".captest"],
				"save_mode": "plugin_owned",
			}],
			"ipc_messages": [],
		},
	})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	def.data_directory = data_dir
	var err: Dictionary = def.validate_capabilities()
	_check("plugin_owned panel rejected for host_owned_save capability",
		err.get("error", "") == "capability_no_host_owned_panel",
		"got: %s" % str(err))


func test_validate_host_owned_save_missing_hook() -> void:
	var data_dir: String = _make_plugin_dir([], "ho_nohook")
	var manifest := _make_manifest({
		"capabilities": ["host_owned_save"],
		"ui": {
			"panels": [{
				"name": "main",
				"kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn",
				"scripts": ["ui/Panel.gd"],
				"file_extensions": [".captest"],
				"save_mode": "host_owned",
			}],
			"ipc_messages": [],
		},
	})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	def.data_directory = data_dir
	var err: Dictionary = def.validate_capabilities()
	_check("missing hook detected for host_owned_save",
		err.get("error", "") == "capability_missing_hook",
		"got: %s" % str(err))


# ---------------------------------------------------------------------------
# validate_capabilities() — project_export
# ---------------------------------------------------------------------------

func test_validate_project_export_pass() -> void:
	var manifest := _make_manifest({
		"capabilities": ["project_export"],
		"ui": {
			"panels": [{"name": "main", "kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn", "scripts": ["ui/Panel.gd"]}],
			"ipc_messages": ["x.collect", "x.apply"],
		},
		"project_export": {"collect_channel": "x.collect", "apply_channel": "x.apply"},
	})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	var err: Dictionary = def.validate_capabilities()
	_check("project_export happy path", err.is_empty(), "got: %s" % str(err))


func test_validate_project_export_missing_channels() -> void:
	var manifest := _make_manifest({"capabilities": ["project_export"]})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	var err: Dictionary = def.validate_capabilities()
	_check("project_export missing channels detected",
		err.get("error", "") == "capability_missing_channels",
		"got: %s" % str(err))


# ---------------------------------------------------------------------------
# validate_capabilities() — composition
# ---------------------------------------------------------------------------

func test_validate_no_capabilities_passes() -> void:
	var manifest := _make_manifest({})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	var err: Dictionary = def.validate_capabilities()
	_check("no capabilities = pass-through", err.is_empty(), "got: %s" % str(err))


func test_validate_multiple_capabilities() -> void:
	var data_dir: String = _make_plugin_dir(
		["_on_panel_save_request", "_on_panel_load_request"], "multi")
	var manifest := _make_manifest({
		"capabilities": ["project_state", "host_owned_save", "project_export"],
		"ui": {
			"panels": [{
				"name": "main",
				"kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn",
				"scripts": ["ui/Panel.gd"],
				"file_extensions": [".captest"],
				"save_mode": "host_owned",
			}],
			"ipc_messages": ["x.s", "x.d", "x.c", "x.a"],
		},
		"project_file": {"serialize_channel": "x.s", "deserialize_channel": "x.d"},
		"project_export": {"collect_channel": "x.c", "apply_channel": "x.a"},
	})
	var def: PluginDefinition = PluginDefinition_._from_dict_internal(manifest)
	def.data_directory = data_dir
	var err: Dictionary = def.validate_capabilities()
	_check("all three caps satisfied together", err.is_empty(), "got: %s" % str(err))


# ---------------------------------------------------------------------------
# PluginDB.install() integration
# ---------------------------------------------------------------------------

func test_pluginddb_install_blocks_on_capability_error() -> void:
	# Build a real on-disk plugin: manifest declares project_state but the
	# panel script is missing the required hooks.  PluginDB.install() should
	# refuse and surface the structured error.
	var unique_id: String = "captestblock%d" % Time.get_ticks_usec()
	var dir: String = _make_plugin_dir([], unique_id)
	var manifest_path: String = dir.path_join("manifest.json")
	var manifest := {
		"id": unique_id,
		"name": "Capability Block Test",
		"version": "0.1.0",
		"backend": {"transport": "stdio", "entrypoint": "echo"},
		"capabilities": ["project_state"],
		"ui": {
			"panels": [{
				"name": "main",
				"kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn",
				"scripts": ["ui/Panel.gd"],
			}],
			"ipc_messages": ["x.s", "x.d"],
		},
		"project_file": {"serialize_channel": "x.s", "deserialize_channel": "x.d"},
	}
	var f := FileAccess.open(manifest_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(manifest))
	f.close()

	var db: PluginDB = PluginDB_.new()
	var result = db.install(manifest_path)
	_check("install rejected when capability hooks missing",
		result == null,
		"expected null, got %s" % str(result))
	var err: Dictionary = db.get_last_install_error()
	_check("install surfaces capability error",
		err.get("error", "") == "capability_missing_hook",
		"got: %s" % str(err))
	# Belt-and-suspenders: in case install ever succeeded, drop the record so
	# subsequent runs aren't polluted by user://plugins/plugins.json carry-over.
	db.remove(unique_id)


func test_plugindb_install_succeeds_when_capabilities_satisfied() -> void:
	var unique_id: String = "captestpass%d" % Time.get_ticks_usec()
	var dir: String = _make_plugin_dir(
		["_on_panel_save_request", "_on_panel_load_request"], unique_id)
	var manifest_path: String = dir.path_join("manifest.json")
	var manifest := {
		"id": unique_id,
		"name": "Capability Pass Test",
		"version": "0.1.0",
		"backend": {"transport": "stdio", "entrypoint": "echo"},
		"capabilities": ["project_state"],
		"ui": {
			"panels": [{
				"name": "main",
				"kind": "godot_scene",
				"entry_scene": "ui/Panel.tscn",
				"scripts": ["ui/Panel.gd"],
			}],
			"ipc_messages": ["x.s", "x.d"],
		},
		"project_file": {"serialize_channel": "x.s", "deserialize_channel": "x.d"},
	}
	var f := FileAccess.open(manifest_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(manifest))
	f.close()

	var db: PluginDB = PluginDB_.new()
	var result = db.install(manifest_path)
	_check("install succeeds when capability satisfied",
		result != null and result.id == unique_id,
		"got: %s, last_err=%s" % [str(result), str(db.get_last_install_error())])
	db.remove(unique_id)


# ---------------------------------------------------------------------------
# T4 U4: validate_files_path wrapper
# ---------------------------------------------------------------------------
# Pure unit tests of the wrapper. No callers yet — T5's host.files.read/write
# wires it in. These tests pin the contract so the T5 implementer can lean on
# the success/error envelope shape without re-validating it.

const _BrokerStatic = preload("res://Scripts/Services/Plugins/CapabilityBroker.gd")


func test_validate_files_path_empty_input() -> void:
	var res: Dictionary = _BrokerStatic.validate_files_path("p", "", ["/tmp"])
	_check("validate_files_path: empty path → schema_validation_failed",
		res.get("error_code", "") == "schema_validation_failed",
		"got: %s" % str(res))


func test_validate_files_path_in_scope() -> void:
	var res: Dictionary = _BrokerStatic.validate_files_path("p", "/tmp/foo.txt", ["/tmp"])
	_check("validate_files_path: in-scope path → success",
		res.get("success", false), "got: %s" % str(res))
	var inner: Dictionary = res.get("result", {})
	_check("validate_files_path: success returns normalized path",
		inner.get("path", "") == "/tmp/foo.txt", "got: %s" % str(inner))


func test_validate_files_path_out_of_scope() -> void:
	var res: Dictionary = _BrokerStatic.validate_files_path("p", "/etc/passwd", ["/tmp"])
	_check("validate_files_path: out-of-scope → target_not_allowlisted",
		res.get("error_code", "") == "target_not_allowlisted",
		"got: %s" % str(res))


func test_validate_files_path_traversal_normalized_then_rejected() -> void:
	# T5 hardening: explicit `..` segments are rejected as schema_validation_failed
	# BEFORE simplify_path collapses them. The pre-T5 behavior (normalize then
	# allowlist-fail) would also have rejected this path, but the new error
	# class gives a clearer audit signal that the plugin attempted traversal
	# rather than asking for a known-bad path.
	var res: Dictionary = _BrokerStatic.validate_files_path(
		"p", "/tmp/../etc/passwd", ["/tmp"])
	_check("validate_files_path: traversal rejected as schema_validation_failed",
		res.get("error_code", "") == "schema_validation_failed",
		"got: %s" % str(res))


func test_validate_files_path_user_prefix_expanded() -> void:
	# user:// paths are globalized to the project's user data dir before
	# scope check. Allowing the same user:// prefix should match.
	var user_dir: String = ProjectSettings.globalize_path("user://")
	var res: Dictionary = _BrokerStatic.validate_files_path(
		"p", "user://plugins/data/foo.json", [user_dir])
	_check("validate_files_path: user:// prefix expanded and accepted",
		res.get("success", false), "got: %s" % str(res))


func test_validate_files_path_empty_allowlist_rejects() -> void:
	# is_path_in_scope returns false on empty allowed_paths — the wrapper
	# surfaces that as target_not_allowlisted, not a silent pass.
	var res: Dictionary = _BrokerStatic.validate_files_path("p", "/tmp/x.txt", [])
	_check("validate_files_path: empty allowlist → rejected",
		res.get("error_code", "") == "target_not_allowlisted",
		"got: %s" % str(res))


# ---------------------------------------------------------------------------
# T5 hardening: relative-path / `..` / prefix-substring guards
# ---------------------------------------------------------------------------

func test_validate_files_path_relative_rejected() -> void:
	# Relative paths can never pass the scope check (allowed_paths are absolute)
	# and are likely to be a programming error. Reject as schema_validation_failed
	# so the audit trail is explicit instead of "out of scope" noise.
	var res: Dictionary = _BrokerStatic.validate_files_path(
		"p", "tmp/foo.txt", ["/tmp"])
	_check("validate_files_path: relative path → schema_validation_failed",
		res.get("error_code", "") == "schema_validation_failed",
		"got: %s" % str(res))


func test_validate_files_path_dotdot_segment_rejected() -> void:
	# `..` somewhere in the middle of an absolute path also rejected before
	# normalization. Defense in depth against simplify_path's handling.
	var res: Dictionary = _BrokerStatic.validate_files_path(
		"p", "/tmp/scope/../escape", ["/tmp/scope"])
	_check("validate_files_path: mid-path .. → schema_validation_failed",
		res.get("error_code", "") == "schema_validation_failed",
		"got: %s" % str(res))


func test_validate_files_path_prefix_substring_rejected() -> void:
	# /tmp/foobar must NOT be considered in scope of /tmp/foo. Pre-hardening
	# this leaked because begins_with treats the strings as raw substrings.
	var res: Dictionary = _BrokerStatic.validate_files_path(
		"p", "/tmp/foobar/secret.txt", ["/tmp/foo"])
	_check("validate_files_path: /tmp/foobar/* not in scope of /tmp/foo",
		res.get("error_code", "") == "target_not_allowlisted",
		"got: %s" % str(res))


func test_validate_files_path_exact_match_accepted() -> void:
	# A grant for /tmp/foo permits operating on /tmp/foo itself (the file or
	# directory at that path), not just children.
	var res: Dictionary = _BrokerStatic.validate_files_path(
		"p", "/tmp/foo", ["/tmp/foo"])
	_check("validate_files_path: exact-match scope → accepted",
		res.get("success", false), "got: %s" % str(res))


func test_validate_files_path_subdir_accepted() -> void:
	# Children of a granted scope are still in scope.
	var res: Dictionary = _BrokerStatic.validate_files_path(
		"p", "/tmp/foo/sub/x.txt", ["/tmp/foo"])
	_check("validate_files_path: subdir of scope → accepted",
		res.get("success", false), "got: %s" % str(res))
