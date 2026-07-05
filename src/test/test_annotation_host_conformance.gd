extends SceneTree
## AnnotationHost v2-envelope conformance smoke test.
##
## Run: godot --headless --path src --script test/test_annotation_host_conformance.gd
##
## The shipped validator AnnotationV2Schema.validate() is the AUTHORITATIVE
## envelope shape (kind_payload, anchor.snapshot.position, lifecycle, author-dict,
## view_context, visible_in_views, summary, schema_version==2). This test drives
## ONE representative add through every loadable AnnotationHost and asserts the
## stored envelope passes validate_with_registry:
##
##   - TextEditorAnnotationHost  (core, res://) — the original conformant host.
##   - CadAnnotationHost          (off-tree plugin) — made conformant this round.
##   - PcbAnnotationHost          (off-tree plugin) — already conformant.
##
## It also asserts the CAD accept-old-on-read normalization: a legacy
## payload-shaped CAD envelope loads and normalizes to a validator-passing v2
## envelope (payload → kind_payload + synthesized lifecycle/visible_in_views/
## summary/author-dict).
##
## Conventions mirror test_pcb_plugin_smoke.gd: SceneTree script, await
## process_frame, check() tally, behavior-not-existence (call methods + inspect
## return values; never class_exists/has_method). Off-tree scripts are loaded via
## load() at RUNTIME so a bad path FAILS a test rather than aborting parse.
##
## res:// == src/, so res://../../minerva-plugins == C:/github/minerva-plugins.

const SCHEMA_SCRIPT_PATH := "res://Scripts/Services/Annotations/AnnotationV2Schema.gd"
const CAD_HOST_SCRIPT_PATH := "res://../../minerva-plugins/cad/ui/CadAnnotationHost.gd"
const PCB_HOST_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PcbAnnotationHost.gd"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== AnnotationHost v2-envelope conformance ===\n")

	# Autoloads / class registrations settle lazily in --script mode.
	await process_frame

	_test_text_host_conformance()
	_test_cad_host_conformance()
	_test_cad_legacy_read_normalization()
	_test_pcb_host_conformance()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── TextEditorAnnotationHost (core) ───────────────────────────────────────────

func _test_text_host_conformance() -> void:
	print("-- TextEditorAnnotationHost: representative add → validator-passing --")
	var host := TextEditorAnnotationHost.new()
	host.set_text("hello world")
	var ann_id: String = host.add_comment_at(0, 5, "review this token", "range", "human")
	check("text host add_comment_at returns a non-empty id", ann_id != "",
			"got id='%s'" % ann_id)
	var stored := host.get_all_annotations()
	check("text host stored exactly one annotation", stored.size() == 1)
	if stored.size() == 1:
		_assert_valid("text host", stored[0], host.get_registry())


# ── CadAnnotationHost (off-tree plugin) ───────────────────────────────────────

func _test_cad_host_conformance() -> void:
	print("\n-- CadAnnotationHost: representative add → validator-passing --")
	var host: AnnotationHost = _load_host(CAD_HOST_SCRIPT_PATH)
	check("CadAnnotationHost loads + instantiates", host != null)
	if host == null:
		return
	var registry: AnnotationRegistry = host.get_registry()
	check("cad host self-builds a registry (has cad_edge_number)",
			registry != null and registry.get_annotation_kind(&"cad_edge_number") != null)

	# Representative add. The host normalizes + validates before storing.
	var ann_id: String = host.add_annotation({
		"kind": "cad_edge_number",
		"anchor": {"plugin": "cad", "type": "edge", "id": 5},
		"kind_payload": {"text": "fillet this edge", "box_offset": [0.0, 0.0, 0.0]},
		"author": "human",
	})
	check("cad host add_annotation returns a non-empty id (validated + stored)",
			ann_id != "", "got id='%s' — validation likely failed (see warnings)" % ann_id)
	var stored: Array = host.get_annotations()
	check("cad host stored exactly one annotation", stored.size() == 1)
	if stored.size() == 1:
		var env: Dictionary = stored[0]
		_assert_valid("cad host", env, registry)
		check("cad envelope uses 'kind_payload' (conformant) not 'payload'",
				env.has("kind_payload") and not env.has("payload"))
		check("cad envelope has lifecycle/visible_in_views/summary + author-dict",
				env.get("lifecycle", "") == "open"
				and env.get("visible_in_views", []) == ["all"]
				and str(env.get("summary", "")) != ""
				and env.get("author", {}) is Dictionary
				and str((env.get("author", {}) as Dictionary).get("kind", "")) == "human")

	# Negative: a non-conformant envelope with NO valid anchor id must be rejected.
	print("\n-- cad host: unanchored envelope is rejected (conformance gate bites) --")
	var bad_id: String = host.add_annotation({
		"kind": "cad_edge_number",
		"anchor": {"plugin": "cad", "type": "edge"},  # missing id
		"kind_payload": {"text": "no anchor id"},
	})
	check("cad host rejects anchorless envelope (empty id)", bad_id == "",
			"got id='%s' — schema gate did NOT bite" % bad_id)


func _test_cad_legacy_read_normalization() -> void:
	print("\n-- CadAnnotationHost: legacy payload-shaped envelope normalizes on read --")
	var host: AnnotationHost = _load_host(CAD_HOST_SCRIPT_PATH)
	if host == null:
		check("CadAnnotationHost loads (legacy-read test)", false)
		return
	# Old shape: `payload` (not kind_payload), bare string author, no
	# lifecycle/visible_in_views/summary, no anchor.snapshot.
	var legacy := {
		"id": "ann_legacy01",
		"kind": "cad_edge_number",
		"author": "human",
		"view_context": "cad:iso",
		"anchor": {"plugin": "cad", "type": "edge", "id": 3},
		"payload": {"text": "old shape edge note", "box_offset": [1.0, 2.0, 3.0]},
	}
	host.set_annotations([legacy])
	var loaded: Array = host.get_annotations()
	check("legacy envelope loaded (one annotation)", loaded.size() == 1)
	if loaded.size() != 1:
		return
	var norm: Dictionary = loaded[0]
	check("legacy normalized: payload → kind_payload",
			norm.has("kind_payload") and not norm.has("payload"))
	check("legacy normalized: kind_payload preserves original data",
			str((norm.get("kind_payload", {}) as Dictionary).get("text", "")) == "old shape edge note")
	check("legacy normalized: author upgraded to dict {kind:'human'}",
			norm.get("author", {}) is Dictionary
			and str((norm.get("author", {}) as Dictionary).get("kind", "")) == "human")
	check("legacy normalized: synthesized lifecycle/visible_in_views/summary",
			norm.get("lifecycle", "") == "open"
			and norm.get("visible_in_views", []) == ["all"]
			and str(norm.get("summary", "")) != "")
	_assert_valid("cad legacy-normalized", norm, host.get_registry())


# ── PcbAnnotationHost (off-tree plugin) ───────────────────────────────────────

func _test_pcb_host_conformance() -> void:
	print("\n-- PcbAnnotationHost: representative add → validator-passing --")
	var host: AnnotationHost = _load_host(PCB_HOST_SCRIPT_PATH)
	check("PcbAnnotationHost loads + instantiates", host != null)
	if host == null:
		return
	var ann_id: String = host.add_route_hint_at(
			12.0, 9.0, "keep 50R away from U1", "F.Cu", "waypoint", [[12.0, 9.0], [30.0, 9.0]], "human")
	check("pcb host add_route_hint_at returns a non-empty id", ann_id != "",
			"got id='%s'" % ann_id)
	var stored: Array = host.get_annotations()
	check("pcb host stored exactly one annotation", stored.size() == 1)
	if stored.size() == 1:
		_assert_valid("pcb host", stored[0], host.get_registry())


# ── Helpers ───────────────────────────────────────────────────────────────────

func _load_host(path: String) -> AnnotationHost:
	var script: Script = load(path)
	if script == null:
		return null
	return script.new() as AnnotationHost


func _assert_valid(label: String, env: Dictionary, registry: Object) -> void:
	var schema = load(SCHEMA_SCRIPT_PATH).new()
	var result = schema.validate_with_registry(env, registry)
	check("%s: stored envelope passes validate_with_registry" % label,
			not result.has_errors(),
			"errors: %s" % (str(result.to_error_dicts()) if result != null else "<null>"))


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
