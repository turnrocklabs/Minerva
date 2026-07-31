class_name AnnotationSelectTool
extends AnnotationAuthorTool
## SUBSUMED — retired, not reachable from any UI. Superseded by
## AnnotationTransformTool, the one universal manipulation tool (select + move +
## rotate + scale, no mode switching). AnnotationToolbar._construct_tool_for_name
## no longer builds this class and nothing else constructs it outside tests.
## Kept on disk only so its tests and history stay readable; slated for deletion.
## Do NOT re-list it in a toolbar and do NOT add features here.
##
## First MANIPULATION tool — pattern-establishing for Translate/Rotate/Scale.
##
## Unlike author tools (arrow, text, …) which CREATE new annotations, Select
## picks an existing annotation, drives the host's selection state, and supports
## Delete-key removal. It is a non-kind tool: instantiated directly by the
## toolbar's Tools section, not returned from any AnnotationKind.author_ui().
##
## State machine: stateless. Selection is single-click, lives on the host
## (host.get_selected_annotation_id()) — not on the tool. This means selection
## persists across tool switches (per design — selection is HOST state).
##
## Interaction model:
##   - Left-click on an annotation         → host.set_selected_annotation_id(id)
##   - Left-click outside any annotation   → host.set_selected_annotation_id("")
##   - Right-click                         → no-op (returns false)
##   - Delete key (via mods=KEY_DELETE)    → host.remove_annotation(selected_id)
##                                           if a selection exists; else no-op.
##   - Escape (via mods=KEY_ESCAPE)        → host.set_selected_annotation_id("")
##
## Hit-test:
##   Iterates host.get_annotations() in REVERSE so the topmost (last-drawn)
##   annotation wins when several overlap. Uses kind.hit_test(ann, doc_pos, 8.0)
##   for per-kind detection.
##
## Halo rendering:
##   draw_preview() draws a 2-px outlined magenta rectangle at the selected
##   annotation's bounds, grown by a small inset so the halo doesn't perfectly
##   clip the annotation.
##
## Signals:
##   This tool emits NO annotation_ready / annotation_modified. Selection and
##   deletion are HOST state changes that the host itself broadcasts via its
##   own selection_changed and annotations_changed signals. cancelled() is
##   unused here too (Escape simply clears selection rather than aborting).

# ── Selection-halo style ──────────────────────────────────────────────────────

const _HALO_COLOR: Color  = Color(1.0, 0.2, 0.8)
const _HALO_WIDTH: float  = 2.0
const _HALO_INSET: float  = 4.0   # grow bounds by this many doc-units before drawing
const _HIT_THRESHOLD: float = 8.0

# ── State ─────────────────────────────────────────────────────────────────────

var _host: AnnotationHost = null


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	# Selection is HOST state — we don't reset it here. Re-activating Select
	# leaves the existing selection intact.
	_host = host


func on_deactivate() -> void:
	# Selection persists across tool switches by design — drop only the host
	# reference.
	_host = null


# ── Pointer / input ───────────────────────────────────────────────────────────

func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
	if _host == null:
		return false

	# Right-click: no-op. We return false so the host can do its own
	# right-click handling (context menu, pan-drag, …) untouched.
	if button == MOUSE_BUTTON_RIGHT:
		return false

	# Keyboard surfaced via the mods channel (consistent with arrow tool's
	# Escape handling — known smell, tracked separately).
	if mods == KEY_DELETE:
		var sel := _host.get_selected_annotation_id()
		if sel != "":
			_host.remove_annotation(sel)
		# Always consume — Delete is meaningful to Select even when nothing
		# is selected (so it doesn't propagate to other handlers).
		return true

	if mods == KEY_ESCAPE:
		_host.set_selected_annotation_id("")
		return true

	if button != MOUSE_BUTTON_LEFT:
		return false

	# Left-click: hit-test the annotations in reverse order (topmost first).
	var doc_pos := _host.transform_screen_to_doc(pos)
	var registry := _host.get_registry()
	var annotations: Array = _host.get_annotations()

	for i in range(annotations.size() - 1, -1, -1):
		var ann: Dictionary = annotations[i]
		# Host visibility veto (WC-2 C3): a hidden annotation (e.g. a route
		# hint on a filtered-out copper layer) is not hit-testable.
		if not _host.is_annotation_visible(ann):
			continue
		var kind_name := StringName(ann.get("kind", ""))
		var kind: AnnotationKind = null
		if registry != null:
			kind = registry.get_annotation_kind(kind_name)
		if kind == null:
			continue
		if kind.hit_test(ann, doc_pos, _HIT_THRESHOLD):
			_host.set_selected_annotation_id(str(ann.get("id", "")))
			return true

	# No hit — clear selection. We still consume so the host doesn't treat
	# this as an unhandled click.
	_host.set_selected_annotation_id("")
	return true


func on_pointer_move(_pos: Vector2) -> void:
	# Stateless tool — nothing to track on move.
	pass


func on_pointer_up(_pos: Vector2, _button: int, _mods: int) -> bool:
	return false


# ── Halo preview ──────────────────────────────────────────────────────────────

func draw_preview(ctx: AnnotationRenderContext) -> void:
	if _host == null:
		return
	var sel := _host.get_selected_annotation_id()
	if sel == "":
		return

	var registry := _host.get_registry()
	if registry == null:
		return

	var annotations: Array = _host.get_annotations()
	var found: Dictionary = {}
	for ann in annotations:
		if ann is Dictionary and str((ann as Dictionary).get("id", "")) == sel:
			found = ann
			break
	if found.is_empty():
		return

	var kind_name := StringName(found.get("kind", ""))
	var kind := registry.get_annotation_kind(kind_name)
	if kind == null:
		return

	var b: Rect2 = kind.bounds(found).grow(_HALO_INSET)
	ctx.draw_rect(b, _HALO_COLOR, false, _HALO_WIDTH)
