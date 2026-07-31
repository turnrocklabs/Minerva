class_name AnnotationHost
extends RefCounted
## Editor-side protocol for annotation authoring tools.
##
## Design §11.2. A thin interface that authoring tools (AnnotationAuthorTool
## subclasses) use to interact with their host editor. Each editor that hosts an
## AnnotationToolbar subclasses AnnotationHost and overrides these methods.
##
## Base-class implementations are no-ops / sensible defaults so that:
##   - Mock hosts in tests can subclass and override only what they need.
##   - Plugins that miss a method don't crash — they get a logged warning and a
##     safe fallback value.
##
## Ownership: the editor creates one AnnotationHost and passes it to
## AnnotationToolbar.set_host(). The toolbar forwards it to each tool on
## activation via AnnotationAuthorTool.on_activate(host).

const AnnotationResolveCacheScript = preload("res://Scripts/Services/Annotations/AnnotationResolveCache.gd")

const _CANVAS_POINT_KEY := "core/canvas.point"

const BASE_ANNOTATION_KINDS := ["callout", "2d_arrow", "2d_text"]
const BASE_ANNOTATION_TOOLS := ["select"]

# ── Selection ──────────────────────────────────────────────────────────────────

## Emitted when the selected annotation changes. Emits "" when selection is
## cleared. Subclasses MUST emit this when the selected id changes.
## Declared on the base class so all hosts share the contract; subclasses
## are the actual emitters, so the parser can't see usage from this file.
@warning_ignore("unused_signal")
signal selection_changed(annotation_id: String)

## Emitted when the selection SET changes (A8u1 multi-select). Carries every
## selected id; empty array = nothing selected. The last entry is NOT the
## primary — read get_selected_annotation_id() for that.
##
## Relationship to selection_changed(String): the multi API is a strict superset
## layered ON TOP of the single-id API, never beside it. set_selected_annotation_ids()
## always routes the primary through the (virtual) set_selected_annotation_id(),
## so hosts that override the single-id pair — Hello / Cad / presentation-tile /
## nametag — keep working un-edited and keep emitting selection_changed. Consumers
## that only care about "which one is highlighted" need no change at all.
@warning_ignore("unused_signal")
signal selection_set_changed(annotation_ids: PackedStringArray)

## Emitted when the host's VIEW changes (pan / zoom / resize / page flip) so the
## overlay re-renders with the current transform. Hosts with a movable or scaled
## surface emit this; static hosts (hello/text) never do. Declared on the base so
## AnnotationOverlay can connect uniformly (guarded by has_signal).
@warning_ignore("unused_signal")
signal view_changed()

var _anchor_resolvers: Dictionary = {}
var resolve_cache: Object = null


func _init() -> void:
	resolve_cache = AnnotationResolveCacheScript.new()
	# Listen to our OWN selection_changed (A8u1). Every host — base-storage or
	# overriding — emits it whenever the primary moves; that is the one contract
	# all of them already honor, including the ones that emit it directly from
	# remove_annotation() without going through the setter. Subscribing here is
	# what makes the multi-set invalidate on the WRITE rather than only on the
	# next read, which is the difference between "usually consistent" and
	# "cannot hold a ghost". Connected first, so it runs before any consumer.
	selection_changed.connect(_on_primary_selection_changed)

# ── Registry ───────────────────────────────────────────────────────────────────

## Return the AnnotationRegistry used by this editor.
## The toolbar and tools use this to look up kinds.
## Subclasses MUST override; reaching the base implementation indicates a
## missing override (programmer error, not a runtime condition).
func get_registry() -> AnnotationRegistry:
	push_error("[AnnotationHost] get_registry() not overridden — returning null")
	return null


## Return the v2 anchor registry used by this editor, if one is available.
## Subclasses that accept v2 annotations should override this and call
## validate_annotation_anchor() before storing or updating an annotation.
func get_anchor_registry() -> Object:
	return null


func validate_annotation_anchor(annotation: Dictionary) -> Array:
	if not annotation.has("anchor"):
		return []
	var registry := get_anchor_registry()
	if registry == null:
		return ["AnnotationHost has no AnnotationAnchorRegistry"]
	return registry.validate_anchor(annotation["anchor"])


# ── Workbench / plugin-facing capabilities ───────────────────────────────────

## Return the small declarative contract consumed by the shared workbench,
## toolbar, and plugin harnesses. Hosts override this to opt in to richer tools;
## the defaults are intentionally conservative so unsupported actions are hidden.
func get_capabilities() -> Dictionary:
	return AnnotationHost.default_capabilities()


## Return the capability contract with all expected sections present. Consumers
## should call this helper so old hosts that only override a subset still behave
## predictably in the shared dock/workbench.
func get_annotation_capabilities() -> Dictionary:
	return AnnotationHost.normalize_capabilities(get_capabilities())


static func default_capabilities() -> Dictionary:
	return {
		"kinds": [],
		"tools": [],
		"anchor_types": [],
		"lifecycle": {
			"resolve": false,
			"reopen": false,
			"delete": false,
			"repair": false,
			"apply": false,
		},
		"authoring": {
			"add": false,
			"domain_pickers": false,
		},
		"panes": false,
		"body_views": false,
		"filters": ["all", "open", "applied", "resolved", "broken"],
	}


static func normalize_capabilities(raw: Dictionary) -> Dictionary:
	var caps := AnnotationHost.default_capabilities()
	for key in raw.keys():
		var value: Variant = raw[key]
		if value is Dictionary and caps.get(key, null) is Dictionary:
			var merged: Dictionary = (caps[key] as Dictionary).duplicate(true)
			for sub_key in (value as Dictionary).keys():
				merged[sub_key] = (value as Dictionary)[sub_key]
			caps[key] = merged
		else:
			caps[key] = value
	return caps


## Stable document identity for MCP routing and sidecar ownership. Plugins should
## include a document_path when they can persist sidecar mutations safely.
func get_document_identity() -> Dictionary:
	return {
		"kind": "unknown",
		"path": "",
		"display_name": "",
		"save_policy": "host",
	}


func can_persist_live_annotation_changes() -> bool:
	var identity := get_document_identity()
	return not str(identity.get("path", "")).is_empty()


## Projection-agnostic pane descriptors. Multi-view editors return entries like
## {id, display_name, viewport_rect, active, projection_metadata}. Single-view
## editors can leave this empty; the workbench treats that as one implicit pane.
func get_panes() -> Array:
	return []


## Domain pickers let plugins/editor surfaces contribute "current selection"
## anchors without subclassing the workbench.
func get_domain_pickers() -> Array:
	return []


func get_current_selection_anchor(_kind: String = "") -> Dictionary:
	return {}


func get_kind_body_view(_kind: String) -> Control:
	return null


func apply_annotation(_annotation_id: String) -> Dictionary:
	return {"ok": false, "error": "apply_annotation not supported"}


func update_annotation_lifecycle(annotation_id: String, lifecycle: String, patch: Dictionary = {}) -> Dictionary:
	for ann in get_annotations():
		if not ann is Dictionary:
			continue
		var current: Dictionary = (ann as Dictionary).duplicate(true)
		if str(current.get("id", "")) != annotation_id:
			continue
		for key in patch.keys():
			current[key] = patch[key]
		current["lifecycle"] = lifecycle
		current["updated_at"] = int(Time.get_unix_time_from_system())
		if update_annotation(annotation_id, current):
			return {"ok": true, "annotation": current}
		return {"ok": false, "error": "update failed"}
	return {"ok": false, "error": "annotation not found: %s" % annotation_id}


func get_annotation_display_index(annotation: Dictionary) -> int:
	return int(annotation.get("display_index", 0))


# ── V2 anchor resolution ──────────────────────────────────────────────────────

## Resolve an anchor to screen-space for rendering. Hosts with live semantic
## documents should override this or register per-anchor callables; the base
## fallback deliberately marks anchors stale and renders at snapshot.position.
##
## Substrate-owned anchor types (core/canvas.point) are resolved here without
## requiring host registration so arrow/callout/text endpoints work uniformly.
func resolve_anchor(anchor: Dictionary) -> Dictionary:
	var key := _anchor_key(anchor)

	if key == _CANVAS_POINT_KEY:
		var canvas_pos := _canvas_point_position(anchor)
		return {
			"position": canvas_pos,
			"bounds": Rect2(canvas_pos, Vector2.ZERO),
			"stale": false,
			"view_metadata": {},
		}

	var resolver: Variant = _anchor_resolvers.get(key, Callable())
	if resolver is Callable and (resolver as Callable).is_valid():
		return _normalise_resolve_result((resolver as Callable).call(anchor), anchor)

	var pos := _snapshot_position_2d(anchor.get("snapshot", {}))
	return {
		"position": pos,
		"bounds": Rect2(pos, Vector2.ZERO),
		"stale": true,
		"view_metadata": {},
	}


func _canvas_point_position(anchor: Dictionary) -> Vector2:
	var id: Variant = anchor.get("id", null)
	if id is Dictionary:
		var d: Dictionary = id
		return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	return _snapshot_position_2d(anchor.get("snapshot", {}))


## Resolve a *position source* — either an anchor (Dictionary) or an inline
## point (Vector2 / [x, y] / {x, y}) — to a screen-space Vector2.
##
## Returns null when the source cannot be resolved (unknown anchor with no
## resolver, missing payload, etc.). Use this from arrow/callout endpoint
## resolution so kinds do not need to know whether the endpoint is an anchor or
## a free canvas point.
func resolve_position_source(source: Variant) -> Variant:
	if source is Vector2:
		return source
	if source is Vector3:
		return Vector2((source as Vector3).x, (source as Vector3).y)
	if source is Array and (source as Array).size() >= 2:
		return Vector2(float((source as Array)[0]), float((source as Array)[1]))
	if source is Dictionary:
		var d: Dictionary = source
		# Bare {x, y} — promoted to Vector2.
		if d.has("x") and d.has("y") and not d.has("plugin"):
			return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		# Anchor envelope — defer to resolve_anchor; return null only when there
		# is genuinely no signal (no resolver registered AND no snapshot position).
		# Stale anchors with a snapshot position still return that snapshot
		# position so kinds can render broken endpoints in place.
		if d.has("plugin") and d.has("type"):
			var key := "%s/%s" % [str(d.get("plugin", "")), str(d.get("type", ""))]
			var has_resolver: bool = key == _CANVAS_POINT_KEY or _anchor_resolvers.has(key)
			var snapshot: Variant = d.get("snapshot", null)
			var has_snapshot_position: bool = snapshot is Dictionary and (snapshot as Dictionary).has("position")
			if not has_resolver and not has_snapshot_position:
				return null
			var resolved := resolve_anchor(d)
			var pos: Variant = resolved.get("position", null)
			if pos is Vector2:
				return pos
			return _to_vec2(pos)
	return null


## Screen-space hit-test rectangle for an anchor in a view. Subclasses can
## override when hit bounds depend on view_context beyond resolve_anchor().bounds.
func anchor_screen_rect(anchor: Dictionary, _view_context: String) -> Rect2:
	var resolved := resolve_anchor(anchor)
	var bounds: Variant = resolved.get("bounds", Rect2(resolved.get("position", Vector2.ZERO), Vector2.ZERO))
	if bounds is Rect2:
		return bounds
	var pos: Vector2 = resolved.get("position", Vector2.ZERO)
	return Rect2(pos, Vector2.ZERO)


## Register a host-local resolver callable for a full anchor key like
## "core/text.range" or "cad/edge". This is useful for plugin hosts that want
## composition over subclassing.
func register_anchor_resolver(anchor_type: String, resolver: Callable) -> void:
	if anchor_type.strip_edges().is_empty():
		push_warning("[AnnotationHost] Cannot register empty anchor resolver key")
		return
	if not resolver.is_valid():
		push_warning("[AnnotationHost] Cannot register invalid anchor resolver for %s" % anchor_type)
		return
	_anchor_resolvers[anchor_type] = resolver


func has_anchor_resolver_for(anchor_type: String) -> bool:
	return _anchor_resolvers.has(anchor_type)


func _resolve_anchor_cached(anchor: Dictionary, view_context: String) -> Dictionary:
	if resolve_cache == null:
		return resolve_anchor(anchor)
	return resolve_cache.resolve(anchor, self, view_context)


func invalidate_resolve_cache(anchor_type: String = "") -> void:
	if resolve_cache != null and resolve_cache.has_method("invalidate"):
		resolve_cache.invalidate(anchor_type)


func bump_revision() -> void:
	if resolve_cache != null and resolve_cache.has_method("bump_revision"):
		resolve_cache.bump_revision()


func get_revision() -> int:
	if resolve_cache != null and resolve_cache.has_method("revision"):
		return int(resolve_cache.revision())
	return 0


func capture_state_snapshot() -> Variant:
	return null


func restore_state_snapshot(_snapshot: Variant) -> bool:
	return false


func _anchor_key(anchor: Dictionary) -> String:
	return "%s/%s" % [str(anchor.get("plugin", "")), str(anchor.get("type", ""))]


func _normalise_resolve_result(value: Variant, anchor: Dictionary) -> Dictionary:
	if not value is Dictionary:
		var fallback_pos := _snapshot_position_2d(anchor.get("snapshot", {}))
		return {"position": fallback_pos, "bounds": Rect2(fallback_pos, Vector2.ZERO), "stale": true, "view_metadata": {}}

	var result: Dictionary = (value as Dictionary).duplicate(true)
	var pos: Variant = result.get("position", _snapshot_position_2d(anchor.get("snapshot", {})))
	if not pos is Vector2:
		pos = _to_vec2(pos)
	result["position"] = pos

	var bounds: Variant = result.get("bounds", Rect2(pos, Vector2.ZERO))
	if not bounds is Rect2:
		bounds = Rect2(pos, Vector2.ZERO)
	result["bounds"] = bounds

	result["stale"] = bool(result.get("stale", false))
	var meta: Variant = result.get("view_metadata", {})
	result["view_metadata"] = meta if meta is Dictionary else {}
	return result


func _snapshot_position_2d(snapshot: Variant) -> Vector2:
	if not snapshot is Dictionary:
		return Vector2.ZERO
	return _to_vec2((snapshot as Dictionary).get("position", Vector2.ZERO))


func _to_vec2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector3:
		return Vector2(value.x, value.y)
	if value is Array and (value as Array).size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO

# ── Document mutation ──────────────────────────────────────────────────────────

## Add a completed annotation dict to the editor's document.
## Returns the assigned annotation id (substrate-generated "ann_<hex>").
## Subclasses MUST override; reaching the base implementation indicates a
## missing override (programmer error, not a runtime condition).
func add_annotation(_annotation: Dictionary) -> String:
	push_error("[AnnotationHost] add_annotation() not overridden — annotation not stored")
	return ""


## Replace a stored annotation by id. The new_annotation dict is stamped with
## the original id before storing. Returns true on success, false if id unknown.
## Subclass MUST emit annotations_changed (or equivalent) on success.
## Subclasses MUST override; base implementation is a programmer-error trap.
func update_annotation(_annotation_id: String, _new_annotation: Dictionary) -> bool:
	push_error("[AnnotationHost] update_annotation() not overridden")
	return false


## Remove an annotation by id. Returns true if removed, false if id unknown.
## If the removed annotation is currently selected, the selection MUST be
## cleared. Subclasses MUST override; base implementation is a programmer-error trap.
func remove_annotation(_annotation_id: String) -> bool:
	push_error("[AnnotationHost] remove_annotation() not overridden")
	return false


## Selected annotation id backing the default selection implementation below.
var _selected_annotation_id: String = ""


## Track which annotation is currently selected. Empty string = no selection.
## The base implementation stores the id and emits selection_changed on change —
## the old no-op default silently discarded selection on every host that didn't
## override (the Select/Transform tools hit-tested fine but nothing stuck, so no
## halo/gizmo ever appeared). Subclasses with their own selection model may
## still override; they MUST emit selection_changed when the value changes.
##
## A8u1: this remains the PRIMARY-selection API and its meaning is unchanged —
## calling it REPLACES the selection with this one id. The multi-selection set
## below is layered on top and reconciles against whatever this returns, so an
## overriding host needs no edit to participate.
##
## KNOWN EDGE (cold-review R2): the unchanged-id early-return below fires no
## signal, so an external caller re-selecting the CURRENT primary leaves an
## existing multi-set standing rather than collapsing it to one. Unreachable
## from the transform tool (which clears or toggles first); the read-time
## liveness heal bounds the damage. Revisit if an external caller relies on
## re-select-to-collapse.
func set_selected_annotation_id(annotation_id: String) -> void:
	if annotation_id == _selected_annotation_id:
		return
	_selected_annotation_id = annotation_id
	selection_changed.emit(annotation_id)


## Return the current selection id, or "" if none.
func get_selected_annotation_id() -> String:
	return _selected_annotation_id


# ── Multi-selection (A8u1) ────────────────────────────────────────────────────
#
# The set is stored on the base class ONLY. Every host — including the four that
# override the single-id pair with their own backing field — participates without
# an edit, because the two APIs are kept coherent by reconciliation rather than by
# shared storage:
#
#   * WRITES through set_selected_annotation_ids() record the set AND the primary
#     they were written with, then call the virtual set_selected_annotation_id().
#   * WRITES through the plain set_selected_annotation_id() (dock list click, a
#     kind's own select-one tool, a host clearing selection inside
#     remove_annotation) move the primary WITHOUT touching the set. The getter
#     detects the drift and collapses the set to just that primary.
#
# So a single-id write always means "replace the selection with this one", which
# is exactly the pre-A8u1 semantics — no existing call site changes meaning.

## Ids in the current selection set, valid only while _selection_set_primary
## still matches the host's live primary. See get_selected_annotation_ids().
var _selected_annotation_ids: PackedStringArray = PackedStringArray()

## The primary at the moment _selected_annotation_ids was last written. A
## mismatch against the live primary means some single-id call site replaced the
## selection behind our back, which collapses the set.
var _selection_set_primary: String = ""

## True only while set_selected_annotation_ids is routing its primary through the
## virtual single-id setter, so the invalidator below can tell "the set moved the
## primary" from "something else did".
var _applying_selection_set: bool = false


## Invalidate the multi-set whenever the primary moves by any route OTHER than
## set_selected_annotation_ids — a dock click, a kind's select-one tool, a host
## clearing selection inside remove_annotation, an MCP retarget. All of those
## mean "replace the selection with this one", so the set becomes exactly the new
## primary (or empty).
##
## Why a signal rather than only the read-time check in the getter: two single-id
## writes with no read between them (…→ H1 → H2) would otherwise land the primary
## back on the value the set was recorded against, re-validating a set the user
## abandoned two gestures ago. Delete would then destroy an annotation that was
## never selected. Invalidating on the write makes that unrepresentable.
func _on_primary_selection_changed(annotation_id: String) -> void:
	if _applying_selection_set:
		return
	if annotation_id.is_empty():
		_selected_annotation_ids = PackedStringArray()
		_selection_set_primary = ""
		return
	_selected_annotation_ids = PackedStringArray([annotation_id])
	_selection_set_primary = annotation_id


## Return every selected annotation id. Empty when nothing is selected.
## The primary (last-clicked) is get_selected_annotation_id() and is always a
## member when the result is non-empty.
##
## SELF-HEALING: every collapse or prune is WRITTEN BACK, never just returned.
## A read-time-only view would leave the stale array standing, and a later
## single-id write landing back on the old recorded primary would then
## RESURRECT the ghost set — after which Delete removes annotations the user
## never selected. The recorded state must always match what we just reported.
func get_selected_annotation_ids() -> PackedStringArray:
	var primary := get_selected_annotation_id()

	if primary.is_empty():
		# A cleared primary clears the whole selection. Hosts clear the primary
		# from inside remove_annotation(); treating that as "clear everything"
		# is what stops a deleted annotation's id from lingering in the set.
		if not _selected_annotation_ids.is_empty() or not _selection_set_primary.is_empty():
			_selected_annotation_ids = PackedStringArray()
			_selection_set_primary = ""
		return PackedStringArray()

	if _selection_set_primary != primary or not _selected_annotation_ids.has(primary):
		# Drift: a single-id call site replaced the selection behind our back.
		_selected_annotation_ids = PackedStringArray([primary])
		_selection_set_primary = primary
		return _selected_annotation_ids.duplicate()

	# Liveness: remove_annotation() only clears the PRIMARY (base contract), so
	# deleting a non-primary member leaves a dead id behind. Left in place it
	# keeps has_multi_selection() true with one live member — which strands the
	# single-target kind tools (pcb bend/via, hint undo) disarmed while exactly
	# one annotation is visibly highlighted, recoverable only by reselecting.
	var pruned := _prune_dead_selection_ids(_selected_annotation_ids, primary)
	if pruned.size() != _selected_annotation_ids.size():
		_selected_annotation_ids = pruned
	return _selected_annotation_ids.duplicate()


## Drop ids that no longer exist in get_annotations(). `primary` is always kept —
## the host owns it and is authoritative about it. Only runs for real multi-sets,
## so the common single-selection read stays allocation-free.
func _prune_dead_selection_ids(ids: PackedStringArray, primary: String) -> PackedStringArray:
	if ids.size() <= 1:
		return ids
	var live: Dictionary = {}
	for ann in get_annotations():
		if ann is Dictionary:
			live[str((ann as Dictionary).get("id", ""))] = true
	var kept := PackedStringArray()
	for id in ids:
		if id == primary or live.has(id):
			kept.append(id)
	return kept


## Replace the whole selection. `primary` becomes the last-clicked id; when it is
## empty (or not a member) the last entry of `annotation_ids` is used. Duplicates
## are dropped, order is otherwise preserved.
##
## Emits selection_changed(primary) via the virtual single-id setter (so hosts
## with their own selection model stay authoritative) and selection_set_changed
## whenever the SET itself changed — including the case where the primary did not
## move and the single-id setter therefore stayed silent.
func set_selected_annotation_ids(annotation_ids: PackedStringArray, primary: String = "") -> void:
	var unique := PackedStringArray()
	for id in annotation_ids:
		var s := str(id)
		if not s.is_empty() and not unique.has(s):
			unique.append(s)

	var new_primary := primary
	if new_primary.is_empty() or not unique.has(new_primary):
		new_primary = unique[unique.size() - 1] if unique.size() > 0 else ""

	var set_changed: bool = unique != get_selected_annotation_ids()
	_selected_annotation_ids = unique
	_selection_set_primary = new_primary
	# Primary last: listeners woken by selection_changed must already see the
	# reconciled set when they call get_selected_annotation_ids(). The flag stops
	# _on_primary_selection_changed from collapsing the set we just recorded.
	_applying_selection_set = true
	set_selected_annotation_id(new_primary)
	_applying_selection_set = false
	if set_changed:
		selection_set_changed.emit(_selected_annotation_ids.duplicate())


## Add or remove one id (shift-click semantics). The toggled-in id becomes the
## primary; toggling the primary out promotes the last remaining member.
func toggle_selected_annotation_id(annotation_id: String) -> void:
	if annotation_id.is_empty():
		return
	var ids := get_selected_annotation_ids()
	if ids.has(annotation_id):
		var kept := PackedStringArray()
		for id in ids:
			if id != annotation_id:
				kept.append(id)
		set_selected_annotation_ids(kept)
	else:
		var grown := ids.duplicate()
		grown.append(annotation_id)
		set_selected_annotation_ids(grown, annotation_id)


## True when more than one annotation is selected. Kind sub-gestures that need a
## single unambiguous edit target (pcb bend-handle drag, via insert) consult this
## and disarm rather than pick an arbitrary member.
func has_multi_selection() -> bool:
	return get_selected_annotation_ids().size() > 1


## THE selected-id read for every consumer outside the host itself — overlays,
## author tools, dock panes, and off-tree plugin tools. Static and duck-typed so
## the "multi API if present, single-id otherwise" fallback exists exactly once
## instead of being retyped in each consumer.
static func selected_ids_for(host: Object) -> PackedStringArray:
	if host == null:
		return PackedStringArray()
	if host.has_method("get_selected_annotation_ids"):
		return host.get_selected_annotation_ids()
	if not host.has_method("get_selected_annotation_id"):
		return PackedStringArray()
	var primary := str(host.get_selected_annotation_id())
	return PackedStringArray() if primary.is_empty() else PackedStringArray([primary])


## Companion to selected_ids_for for the disarm predicate. Prefers the host's own
## has_multi_selection() so a host with a bespoke selection model stays
## authoritative.
static func multi_selected_for(host: Object) -> bool:
	if host == null:
		return false
	if host.has_method("has_multi_selection"):
		return bool(host.has_multi_selection())
	return AnnotationHost.selected_ids_for(host).size() > 1


## Host-owned per-annotation visibility veto (pcb-ui-native-cluster §4, WC-2;
## C3 bug 019f33d2c9bf). The substrate consults this in the overlay render loop
## AND in every hit-test path (Select/Transform/Translate tools), so an
## annotation the host's view state hides — e.g. a pcb route hint whose
## kind_payload.layer is a copper layer the panel currently filters out — is
## neither drawn nor clickable. Pure UI gating: MCP read surfaces and the
## stored annotation list are unaffected.
## Base: everything visible. Hosts override with view-state-aware logic.
func is_annotation_visible(_annotation: Dictionary) -> bool:
	return true


## Return the current document's annotation list. Manipulation tools iterate
## this to hit-test, render halos, etc. Concrete subclasses store annotations
## internally; the base default returns []. Subclasses override.
func get_annotations() -> Array:
	return []

# ── Coordinate transforms ──────────────────────────────────────────────────────

## Convert a document-space point to screen-space pixels.
## Default: identity (document == screen, useful for tests with zoom=1).
func transform_doc_to_screen(p: Vector2) -> Vector2:
	return p


## Convert a screen-space point to document-space.
## Default: identity.
func transform_screen_to_doc(p: Vector2) -> Vector2:
	return p


## Affine transform mapping DOCUMENT space → on-screen (overlay-local) pixels.
## AnnotationOverlay uses it to RENDER annotations. Pointer input is NOT mapped
## by the overlay — tools receive raw overlay-local pixels and call
## transform_screen_to_doc themselves (the per-tool contract). Default identity
## (document == screen — hello/text hosts). Hosts with a scaled or scrolled
## surface (a fit-to-pane raster preview, a CAD/PCB camera) override this and
## emit view_changed() whenever it changes.
func get_annotation_view_transform() -> Transform2D:
	return Transform2D.IDENTITY


## Screen-pixels-per-document-unit scale hint; kinds use it to size strokes and
## glyphs. Default 1.0. Hosts that scale their surface return that scale.
func get_annotation_zoom() -> float:
	return 1.0

# ── View context ───────────────────────────────────────────────────────────────

## Return the current view context string (e.g. "pcb", "cad:top", "graphics").
## Tools embed this in the annotation envelope they build.
## Default returns "" — override in each editor.
func get_view_context() -> String:
	return ""

# ── Semantic hit-testing ───────────────────────────────────────────────────────

## Return a semantic identifier for whatever is at document-space point doc_pos.
##
## Format conventions (all optional — hosts pick what makes sense):
##   "ui:Label"          — a UI label node named "Label"
##   "label.word:this"   — a specific word in a label
##   "component:R12"     — a PCB/CAD component reference
##   ""                  — nothing meaningful at this point
##
## The return value is written into annotation["anchored_to"] by _stamp_anchor().
## Returning "" is valid and means "no meaningful target here."
## Default returns "" — override in each editor that can identify content.
func describe_point(_doc_pos: Vector2) -> String:
	return ""

# ── Compositing ────────────────────────────────────────────────────────────────

## Render the host's underlying content (NOT annotations) into an Image that
## covers viewport_rect in document space.
##
## Used by render_overlay(include_document=true) to composite the host content
## beneath the annotation layer. Hosts that can produce a viewport image should
## override this; others return null and the overlay falls back to a transparent
## background.
##
## viewport_rect is expressed in document coordinates. The returned Image should
## have dimensions matching the pixel size of that rect (i.e. the caller handles
## coordinate mapping). Returning null is valid and safe.
func render_content_to_image(_viewport_rect: Rect2) -> Image:
	return null

# ── Anchor stamping helpers ────────────────────────────────────────────────────

## Write the semantic anchor for a single annotation in-place.
##
## Computes: kind.primary_anchor_point(annotation) → host.describe_point() →
## annotation["anchored_to"]. Always overwrites anchored_to (even with "") so
## the value always reflects current host state. No-ops silently when the host
## or its registry is null, or when the kind is not registered.
static func _stamp_anchor(annotation: Dictionary, host: AnnotationHost) -> void:
	if host == null:
		return
	var registry := host.get_registry()
	if registry == null:
		return
	var kind_name := StringName(annotation.get("kind", ""))
	var kind := registry.get_annotation_kind(kind_name)
	if kind == null:
		return
	var anchor_point: Vector2 = kind.primary_anchor_point(annotation)
	var target: String = kind.describe_target_point(annotation, anchor_point, host)
	annotation["anchored_to"] = target


## Stamp anchors for every annotation in the list in-place.
##
## Walks annotations and calls _stamp_anchor on each Dictionary entry.
## Intended for use by hosts on save to catch unobserved UI changes
## (e.g. components that moved since the annotation was authored).
static func refresh_all_anchors(annotations: Array, host: AnnotationHost) -> void:
	for ann in annotations:
		if ann is Dictionary:
			_stamp_anchor(ann, host)
