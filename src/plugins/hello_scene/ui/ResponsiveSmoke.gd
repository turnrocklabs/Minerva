class_name Helloscene_ResponsiveSmoke
extends Control
## Smoke-test scene for ResponsiveContainer.
##
## Demonstrates the three layout modes driven by ResponsiveContainer.width_class:
##   lg / xl  → 4-column GridContainer
##   md       → 2-column GridContainer
##   xs / sm  → 1-column VBoxContainer (vertical stack)
##
## Resize the Minerva window or the panel to see the layout switch live.
## The current width class is shown in the header label.

# ---------------------------------------------------------------------------
# Node references (resolved in _ready)
# ---------------------------------------------------------------------------

var _container: ResponsiveContainer = null
var _class_label: Label = null
var _grid: GridContainer = null
var _stack: VBoxContainer = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_container = $ResponsiveContainer
	_class_label = $Header/ClassLabel
	_grid = $ResponsiveContainer/GridContainer
	_stack = $ResponsiveContainer/StackContainer

	# Connect the signal before reading the initial state.
	_container.width_class_changed.connect(_on_width_class_changed)

	# Apply initial layout immediately (no resize event fires at startup).
	_apply_layout(_container.width_class)


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_width_class_changed(new_class: StringName) -> void:
	_apply_layout(new_class)


# ---------------------------------------------------------------------------
# Layout switching
# ---------------------------------------------------------------------------

func _apply_layout(cls: StringName) -> void:
	_class_label.text = "Width class: %s  (%dpx)" % [cls, int(_container.size.x)]

	match cls:
		ResponsiveContainer.CLASS_LG, ResponsiveContainer.CLASS_XL:
			_grid.columns = 4
			_grid.visible = true
			_stack.visible = false

		ResponsiveContainer.CLASS_MD:
			_grid.columns = 2
			_grid.visible = true
			_stack.visible = false

		_: # xs, sm
			_grid.visible = false
			_stack.visible = true
