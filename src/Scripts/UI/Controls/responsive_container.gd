class_name ResponsiveContainer
extends Container
## Bootstrap-style width classifier for Minerva panels and plugin UIs.
##
## ResponsiveContainer watches its own rendered width and emits
## [signal width_class_changed] whenever the width crosses a breakpoint.
## Children lay themselves out normally (anchors, size flags, etc.) — this
## node only classifies the available width; it does NOT reflow children.
##
## Usage (static read):
##   var cls := $MyContainer.width_class   # e.g. &"md"
##
## Usage (reactive):
##   $MyContainer.width_class_changed.connect(_on_width_class_changed)
##   func _on_width_class_changed(cls: StringName) -> void:
##       match cls:
##           ResponsiveContainer.CLASS_LG, ResponsiveContainer.CLASS_XL:
##               _set_4_column_layout()
##           ResponsiveContainer.CLASS_MD:
##               _set_2_column_layout()
##           _:
##               _set_single_column_layout()
##
## Breakpoints (Bootstrap-equivalent):
##   xs  width < 480
##   sm  480 <= width < 768
##   md  768 <= width < 1024
##   lg  1024 <= width < 1440
##   xl  width >= 1440

# ---------------------------------------------------------------------------
# Breakpoint constants — consumers should reference these rather than string
# literals so a rename is a single-point change.
# ---------------------------------------------------------------------------

## Width < 480 px.
const CLASS_XS := &"xs"
## 480 <= width < 768 px.
const CLASS_SM := &"sm"
## 768 <= width < 1024 px.
const CLASS_MD := &"md"
## 1024 <= width < 1440 px.
const CLASS_LG := &"lg"
## width >= 1440 px.
const CLASS_XL := &"xl"

## Breakpoint thresholds in pixels (lower bound of each class above xs).
const BREAKPOINT_SM := 480
const BREAKPOINT_MD := 768
const BREAKPOINT_LG := 1024
const BREAKPOINT_XL := 1440

# ---------------------------------------------------------------------------
# Signal
# ---------------------------------------------------------------------------

## Emitted when the width class changes. [param new_class] is one of the
## CLASS_* constants. Not emitted on every resize — only on transitions.
signal width_class_changed(new_class: StringName)

# ---------------------------------------------------------------------------
# Exported property
# ---------------------------------------------------------------------------

## The current Bootstrap-equivalent width class. Read-only in practice;
## set by the node based on its rendered size.
@export var width_class: StringName = CLASS_LG :
	get = get_width_class

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _current_class: StringName = CLASS_LG

# ---------------------------------------------------------------------------
# Godot lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	# Classify immediately so consumers reading width_class in _ready() see
	# the correct value even before the first resize notification.
	_classify()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			_classify()
		NOTIFICATION_SORT_CHILDREN:
			# Container base class won't lay out children unless we tell it how.
			# Stack all Control children to fill the full bounds — consumers toggle
			# .visible on whichever layout matches the current width class; multiple
			# visible children overlap, which is fine for stack-style switching.
			var rect := Rect2(Vector2.ZERO, size)
			for child in get_children():
				if child is Control:
					fit_child_in_rect(child, rect)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Returns the current width class StringName. Equivalent to reading the
## [member width_class] property.
func get_width_class() -> StringName:
	return _current_class

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

func _classify() -> void:
	var w: float = size.x
	var new_class: StringName = _class_for_width(w)
	if new_class != _current_class:
		_current_class = new_class
		width_class_changed.emit(new_class)


static func _class_for_width(w: float) -> StringName:
	if w >= BREAKPOINT_XL:
		return CLASS_XL
	if w >= BREAKPOINT_LG:
		return CLASS_LG
	if w >= BREAKPOINT_MD:
		return CLASS_MD
	if w >= BREAKPOINT_SM:
		return CLASS_SM
	return CLASS_XS
