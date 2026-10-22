extends SceneTree
## Real panel hook dispatch; no process, policy or persistence substitutions.

class LegacyPanel extends Node:
	var document: Dictionary = {"value": 1}
	func _on_panel_save_request() -> Dictionary:
		return document.duplicate(true)
	func _on_panel_load_request(state: Dictionary) -> void:
		document = state.duplicate(true)

class LivePanel extends LegacyPanel:
	var history: Array[int] = [1, 2]
	var reply: Variant = true
	func _on_panel_capture_live_state() -> Dictionary:
		return {"document": document.duplicate(true), "history": history.duplicate()}
	func _on_panel_restore_live_state(state: Dictionary) -> Variant:
		document = state.document.duplicate(true)
		history.assign(state.history)
		return reply

class CaptureOnly extends LegacyPanel:
	func _on_panel_capture_live_state() -> Dictionary:
		return {"unexpected": true}

class RestoreOnly extends LegacyPanel:
	func _on_panel_restore_live_state(_state: Dictionary) -> bool:
		return true

var passed: int = 0
var failed: int = 0

func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)

func _run() -> void:
	# The host type loads after autoload registration under the --script runner.
	var host = load("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")
	var legacy := LegacyPanel.new()
	check("legacy live capture uses the existing save hook", host.invoke_capture_live_state(legacy) == {"value": 1})
	check("legacy live restore uses the existing load hook", host.invoke_restore_live_state(legacy, {"value": 2}) and legacy.document == {"value": 2})
	legacy.free()
	var live := LivePanel.new()
	check("optional live capture includes transient state", host.invoke_capture_live_state(live) == {"document": {"value": 1}, "history": [1, 2]})
	check("optional restore keeps history outside saved bytes", host.invoke_restore_live_state(live, {"document": {"value": 3}, "history": [5]})
		and live.history == [5] and host.invoke_save(live, {}) == {"value": 3})
	live.reply = "not a boolean"
	check("optional live restore requires explicit boolean success", not host.invoke_restore_live_state(live, {"document": {"value": 3}, "history": [5]}))
	live.free()
	for partial: LegacyPanel in [CaptureOnly.new(), RestoreOnly.new()]:
		check("a partial live-state hook pair refuses capture and restore", host.invoke_capture_live_state(partial) == null
			and not host.invoke_restore_live_state(partial, {"value": 99}) and partial.document == {"value": 1})
		partial.free()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
