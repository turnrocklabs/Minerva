## Reusable panel-driver test helper for host_owned PLUGIN_SCENE panels.
##
## Extracted from test_pcb_plugin_smoke.gd's `_test_panel_save_flow` (the W-15
## regression test — the PANEL's own load→annotate→save flow must write its
## annotation sidecar). Future migration rounds (panel port, annotation
## migration) can reuse this to write panel-hook probes cheaply instead of
## re-deriving the Editor.gd:1117 document shapes + temp-workspace plumbing
## every time.
##
## Off-tree plugin gotcha: plugin panel scripts live OUTSIDE Minerva's res://
## tree (e.g. res://../../minerva-plugins/pcb/ui/PCBPanel.gd), so this helper
## never types a variable AS a plugin class — every panel/host reference here
## is duck-typed (Variant + has_method/get checks). This file is plain script
## (no class_name): it's loaded via preload()/load() by the tests that use it,
## matching the convention already used by test/marketplace_test_helpers.gd.
## Does NOT reference SingletonObject — panel-hook driving is pure GDScript,
## no autoload dependency.
##
## Usage:
##   var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
##   var panel = driver.load_panel("res://../../minerva-plugins/pcb/ui/PCBPanel.gd")
##   var board_dir := driver.make_temp_board_dir("pcb_skel_smoke")
##   var board_path := board_dir + "/flow.pcbskel"
##   driver.drive_load_merged(panel, board_path, {"version": 1, "board": {}, "components": []})
##   var saved := driver.drive_save(panel)
##   driver.cleanup_sidecar(board_path)
##   driver.free_panel(panel)

extends RefCounted


# ---------------------------------------------------------------------------
# Panel load/instantiate
# ---------------------------------------------------------------------------

## Load a panel script by (possibly off-tree) path and instantiate it.
## Returns null if the script fails to load — callers should check() on the
## result themselves so a bad path fails the test loudly rather than crashing
## deeper in the flow.
func load_panel(script_path: String) -> Variant:
	var panel_script: Script = load(script_path)
	if panel_script == null:
		return null
	return panel_script.new()


## Safely free a panel instance. Panels are typically Node-derived
## (MinervaPluginPanel), but this is duck-typed defensively in case a helper
## is reused against a RefCounted-based panel in the future.
func free_panel(panel: Variant) -> void:
	if panel == null:
		return
	if panel is Node:
		(panel as Node).free()
	elif panel is RefCounted:
		pass  # RefCounted frees itself once unreferenced; nothing to do.
	elif panel.has_method("free"):
		panel.free()


# ---------------------------------------------------------------------------
# Panel-hook drivers
# ---------------------------------------------------------------------------

## Drive _on_panel_load_request with an Editor.gd:1117-shaped document: the
## host ALWAYS includes `file_path`; when the on-disk body parses as a JSON
## Dictionary, its keys are merged in (this is the "JSON body" shape a saved
## host_owned file round-trips through). `extra_fields` supplies that merged
## body (e.g. {version, kind, board, components}).
func drive_load_merged(panel: Variant, file_path: String, extra_fields: Dictionary = {}) -> void:
	var doc: Dictionary = {"file_path": file_path}
	doc.merge(extra_fields, true)
	panel._on_panel_load_request(doc)


## Drive _on_panel_load_request with the raw-text shape: {file_path, raw_text}.
## This is what the host hands the panel when the on-disk body is NOT valid
## JSON (non-JSON / legacy document bodies) — the panel must parse raw_text
## itself.
func drive_load_raw_text(panel: Variant, file_path: String, raw_text: String) -> void:
	panel._on_panel_load_request({"file_path": file_path, "raw_text": raw_text})


## Drive _on_panel_save_request and return its result dict verbatim.
func drive_save(panel: Variant) -> Dictionary:
	return panel._on_panel_save_request()


# ---------------------------------------------------------------------------
# Temp-workspace utilities
# ---------------------------------------------------------------------------

## Resolve a usable temp root: TEMP, then TMP, then Godot's user-data dir —
## the same fallback chain test_pcb_plugin_smoke.gd's sidecar tests already
## relied on. Backslashes are normalised to forward slashes (Windows TEMP/TMP).
func temp_root() -> String:
	var tmp_dir: String = OS.get_environment("TEMP")
	if tmp_dir == "":
		tmp_dir = OS.get_environment("TMP")
	if tmp_dir == "":
		tmp_dir = OS.get_user_data_dir()
	return tmp_dir.replace("\\", "/")


## Make (and return) a fresh temp board directory "<temp_root>/<subdir>".
func make_temp_board_dir(subdir: String) -> String:
	var board_dir := temp_root() + "/" + subdir
	DirAccess.make_dir_recursive_absolute(board_dir)
	return board_dir


## Sidecar path derivation: "<file>.annotations.json" — the convention used by
## AnnotationSidecar / every host_owned panel that persists annotations
## alongside its board/document file.
func sidecar_path_for(board_path: String) -> String:
	return board_path + ".annotations.json"


## Write `contents` (String) to board_path. Returns true on success. Lets
## tests stage an on-disk board file cheaply when a scenario needs the panel
## (or a future load path) to read from disk rather than being driven purely
## via drive_load_merged/drive_load_raw_text.
func write_board_file(board_path: String, contents: String) -> bool:
	var f := FileAccess.open(board_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(contents)
	f.close()
	return true


## Remove the sidecar file for board_path if it exists (idempotent cleanup).
func cleanup_sidecar(board_path: String) -> void:
	var sc := sidecar_path_for(board_path)
	if _is_under_temp_root(sc) and FileAccess.file_exists(sc):
		DirAccess.remove_absolute(sc)


## Remove board_path itself if it exists (idempotent cleanup).
func cleanup_board_file(board_path: String) -> void:
	if _is_under_temp_root(board_path) and FileAccess.file_exists(board_path):
		DirAccess.remove_absolute(board_path)


## Cleanup guard: deletions only ever target the temp workspace. A test bug
## passing a real project path becomes a loud no-op instead of a deletion.
func _is_under_temp_root(path: String) -> bool:
	if path.replace("\\", "/").begins_with(temp_root() + "/"):
		return true
	push_warning("[plugin_panel_driver] refusing cleanup outside temp root: %s" % path)
	return false
