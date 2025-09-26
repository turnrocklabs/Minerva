extends Control

#@onready var _main_editor_container: VBoxContainer = %MainEditorContainer
@onready var _editor_tab_bar: TabBar = %EditorTabBar
#@onready var _add_tab_button: Button = %AddTabButton
@onready var _tabs_panel_container: PanelContainer = %TabsPanelContainer


func _ready() -> void:
	pass # Replace with function body.



func _process(_delta: float) -> void:
	pass


func _on_add_tab_button_pressed() -> void:
	
	var graphic_editor: = GraphicsEditorV2.new()
	
	_tabs_panel_container.add_child(graphic_editor, true)
	
	_editor_tab_bar.add_tab("Graphic tab %s" % str(_editor_tab_bar.tab_count))
	_editor_tab_bar.set_tab_metadata(_editor_tab_bar.tab_count - 1, graphic_editor)
	
	
