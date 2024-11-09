class_name TerminalTabContainer
extends VBoxContainer

signal _tab_metadata_ready()

@export var _tab_bar: TabBar
@export var _controls_container: Control


var _last_terminal_num = 0

func _ready():
	_on_new_tab_button_pressed() # start with one tab open already

func _on_new_tab_button_pressed():
	_tab_bar.add_tab("Terminal %s" % _last_terminal_num)
	_last_terminal_num += 1

	var terminal_node = Terminal.create()
	terminal_node.visible = false
	_tab_bar.set_tab_metadata(_tab_bar.tab_count-1, terminal_node)
	_controls_container.add_child(terminal_node)

	_tab_metadata_ready.emit()

	_tab_bar.current_tab = _tab_bar.tab_count-1


func _on_tab_bar_tab_changed(tab: int):
	for child in _controls_container.get_children():
		child.visible = false
	
	if not _tab_bar.get_tab_metadata(tab):
		await _tab_metadata_ready
	
	var terminal_control: Terminal = _tab_bar.get_tab_metadata(tab)
	terminal_control.visible = true


func _on_tab_bar_tab_close_pressed(tab: int):
	var terminal_control: Terminal = _tab_bar.get_tab_metadata(tab)
	_tab_bar.remove_tab(tab)
	terminal_control.queue_free()
