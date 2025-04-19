class_name TerminalTabContainer
extends VBoxContainer

signal _tab_metadata_ready()

@export var _tab_bar: TabBar
@export var _controls_container: Control


# func _ready():
# 	_on_new_tab_button_pressed() # starting with one tab open already


func _on_visibility_changed() -> void:
	if is_visible_in_tree() and _tab_bar.tab_count == 0:
		_on_new_tab_button_pressed()

func _on_new_tab_button_pressed():

	var terminal_node = TerminalNew.create()
	terminal_node.name = "Terminal "
	terminal_node.visible = false

	_controls_container.add_child(terminal_node, true)

	_tab_bar.add_tab(terminal_node.name)
	_tab_bar.set_tab_metadata(_tab_bar.tab_count-1, terminal_node)
		
	_tab_metadata_ready.emit()

	_tab_bar.current_tab = _tab_bar.tab_count-1


func _on_tab_bar_tab_changed(tab: int):
	if tab == -1: return
	for child in _controls_container.get_children():
		child.visible = false
	
	if not _tab_bar.get_tab_metadata(tab):
		await _tab_metadata_ready
	
	var terminal_control: TerminalNew = _tab_bar.get_tab_metadata(tab)
	
	terminal_control.visible = true


func _on_tab_bar_tab_close_pressed(tab: int):
	var terminal_control: TerminalNew = _tab_bar.get_tab_metadata(tab)
	_tab_bar.remove_tab(tab)
	terminal_control.queue_free()
