extends Node
## Opt-in final-package check of the CEF browser and native bridge.

class DelayToolModule extends RefCounted:
	signal entered
	var tree: SceneTree
	func _init(value: SceneTree) -> void:
		tree = value
	func can_handle(tool_name: String) -> bool:
		return tool_name == "minerva_bridge_probe_delay"
	func handle(_tool_name: String, _arguments: Dictionary) -> Dictionary:
		entered.emit()
		await tree.create_timer(0.5, true, false, true).timeout
		return {"success": true, "delayed": true}

const PROBE_HTML := """<!doctype html><html><body><script>
(async function() {
 try {
  const navigation = performance.getEntriesByType('navigation')[0];
  if (navigation && navigation.type === 'reload')
   throw new Error('reload escaped the native document lock');
  let earlyReplies = 0;
  const originalReply = window.minerva._ipcReply;
  window.minerva._ipcReply = function(result) { earlyReplies++; originalReply(result); };
  await new Promise(resolve => setTimeout(resolve, 700));
  window.minerva._ipcReply = originalReply;
  if (earlyReplies !== 0) throw new Error('retired document reply reached replacement');
  await window.minerva.call('minerva_tool_search', {query: 'note', limit: 1});
  window.open('https://foreign.invalid/', '_blank');
  const frameResult = new Promise(resolve => {
   window.addEventListener('message', event => resolve(event.data), {once: true});
   setTimeout(() => resolve('navigation-blocked'), 10000);
  });
  const frame = document.createElement('iframe');
  frame.src = 'data:text/html,<script>(async()=>{try{await parent.minerva.call("minerva_tool_search",{query:"foreign"});parent.postMessage("foreign-authority","*")}catch(e){parent.postMessage("foreign-blocked","*")}})()<\\/script>';
  document.body.appendChild(frame);
  const frameStatus = await frameResult;
  if (frameStatus !== 'foreign-blocked')
   throw new Error('foreign frame acquired authority');
  location.assign('https://foreign.invalid/replacement');
  location.reload();
  await new Promise(resolve => setTimeout(resolve, 100));
  await window.minerva.call('minerva_tool_search', {query: 'note', limit: 1});
  await window.minerva.pluginIPC('bridge.probe.ack', {success: true});
 } catch (_) {
  await window.minerva.pluginIPC('bridge.probe.ack', {success: false});
 }
})();
</script></body></html>"""

const RETIRED_HTML := """<!doctype html><html><body><script>
(async function() {
 const pending = window.minerva.call('minerva_bridge_probe_delay', {});
 try { await pending; await window.minerva.pluginIPC('bridge.probe.ack', {success: false}); }
 catch (_) {}
})();
</script></body></html>"""


func run() -> void:
	print("PACKAGED_BRIDGE_PHASE=entry method=%s driver=%s device=%s" % [
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_current_rendering_driver_name(),
		RenderingServer.get_video_adapter_name()])
	var singleton = get_tree().root.get_node_or_null("SingletonObject")
	if singleton == null:
		_finish(false)
		return
	var manager = singleton.get_mcp_manager()
	manager.connect_minerva_server()
	var delay_module = DelayToolModule.new(get_tree())
	manager.minerva_server._modules.append(delay_module)
	manager.minerva_server._register_tool("minerva_bridge_probe_delay",
		"Packaged bridge replacement probe", {"type": "object", "properties": {}})
	var cef_preactivation_ok: bool = await _probe_cef_preactivation_cleanup()
	var cef_ok: bool = cef_preactivation_ok and await _probe_editor(
		load("res://Scripts/UI/Controls/WebViewEditor/CefWebViewEditor.gd"), "CEF", delay_module)
	manager.minerva_server._modules.erase(delay_module)
	manager.tool_registry.erase("minerva_bridge_probe_delay")
	_finish(cef_ok)


func _probe_editor(script: Script, label: String, delay_module: DelayToolModule) -> bool:
	var editor = script.new()
	var completed: Array = [false, false]
	editor.bridge_probe_completed.connect(func(success: bool) -> void:
		if not completed[0]:
			completed[0] = true
			completed[1] = success)
	var started: Array = [false]
	var on_delay_started := func() -> void: started[0] = true
	delay_module.entered.connect(on_delay_started, CONNECT_ONE_SHOT)
	add_child(editor)
	editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	editor.set_html(RETIRED_HTML)
	var retired_path: String = editor._document.file_path
	# The engine's cold start is not what this phase measures: on a software-
	# rendered runner the first browser can take longer than the call window
	# just to reach its page. Wait for the retired page to load (or for its
	# call to arrive, whichever is first) before that window opens; the
	# verifier's launch deadline still bounds the whole probe.
	var loaded: Array = [false]
	if editor._cef != null and editor._cef.has_signal("load_finished"):
		editor._cef.load_finished.connect(
			func(_url: String, _status: int) -> void: loaded[0] = true, CONNECT_ONE_SHOT)
	var load_started: int = Time.get_ticks_msec()
	while not loaded[0] and not started[0] \
			and Time.get_ticks_msec() - load_started < 25000:
		await get_tree().process_frame
	print("PACKAGED_BRIDGE_PHASE=%s:first-page loaded=%s after_ms=%d" % [
		label, loaded[0], Time.get_ticks_msec() - load_started])
	# Replacing the host document revokes its capability and pending context
	# before the delayed old request can return or evaluate into the new view.
	var start_deadline: int = Time.get_ticks_msec() + 10000
	while not started[0] and Time.get_ticks_msec() < start_deadline:
		await get_tree().process_frame
	if not started[0]:
		print("PACKAGED_BRIDGE_PHASE=%s:retired-not-started" % label)
		remove_child(editor)
		editor.free()
		return false
	editor.set_html(PROBE_HTML)
	var current_path: String = editor._document.file_path
	if not await _wait_file_absent(retired_path, 5000) \
			or not FileAccess.file_exists(current_path):
		print("PACKAGED_BRIDGE_PHASE=%s:document-lifetime-failed" % label)
		remove_child(editor)
		editor.free()
		return false
	# Same rule for the replacement page: its browser is created cold too, so
	# the completion window opens once the page has loaded (or has already
	# answered), and the wait is printed with the verdict.
	var probe_loaded: Array = [false]
	if editor._cef != null and editor._cef.has_signal("load_finished"):
		editor._cef.load_finished.connect(
			func(_url: String, _status: int) -> void: probe_loaded[0] = true, CONNECT_ONE_SHOT)
	var probe_started: int = Time.get_ticks_msec()
	while not probe_loaded[0] and not completed[0] \
			and Time.get_ticks_msec() - probe_started < 25000:
		await get_tree().process_frame
	var deadline: int = Time.get_ticks_msec() + 20000
	while not completed[0] and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var passed: bool = completed[0] and completed[1]
	print("PACKAGED_BRIDGE_PHASE=%s:%s loaded=%s answered=%s after_ms=%d" % [label,
		"ready" if passed else "failed", probe_loaded[0], completed[0],
		Time.get_ticks_msec() - probe_started])
	remove_child(editor)
	editor.free()
	var closed: bool = await _wait_file_absent(current_path, 5000)
	return passed and closed


func _probe_cef_preactivation_cleanup() -> bool:
	var Document = load("res://Scripts/UI/Controls/WebViewEditor/WebDocumentLifetime.gd")
	var document = Document.create(
		"<script>const cap='__MINERVA_DOCUMENT_CAPABILITY__';</script>", 0)
	var cef: Control = ClassDB.instantiate("CefTexture")
	if document == null or cef == null:
		if document != null:
			document.dispose()
		return false
	var path: String = document.file_path
	var locked: bool = cef.lock_initial_document(document.file_url,
		ProjectSettings.globalize_path(path))
	cef.free()
	var cleaned: bool = locked and await _wait_file_absent(path, 3000)
	print("PACKAGED_BRIDGE_PHASE=CEF:%s" %
		("preactivation-clean" if cleaned else "preactivation-cleanup-failed"))
	return cleaned


func _wait_file_absent(path: String, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while FileAccess.file_exists(path) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return not FileAccess.file_exists(path)


func _finish(passed: bool) -> void:
	print("PACKAGED_BRIDGE_OK" if passed else "PACKAGED_BRIDGE_FAILED")
	get_tree().quit(0 if passed else 1)
