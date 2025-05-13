class_name RecentPopupButton extends VBoxContainer

@onready var drop_top: HSeparator = %DropTop
@onready var drop_bottom: HSeparator = %DropBottom
@onready var recent_btn: Button = %RecentBtn
@onready var exit_btn: Button = %exitBtn


var index: = 0
var drop_top_bool: = true

func _process(_delta: float) -> void:
	if not drop_top.visible and not drop_bottom.visible: return
	
	if not get_global_rect().has_point(get_global_mouse_position()):
		drop_top.visible = false
		drop_bottom.visible = false


func _notification(notification_type):
	match notification_type:
		NOTIFICATION_DRAG_END:
			recent_btn.mouse_filter = Control.MOUSE_FILTER_STOP
			exit_btn.mouse_filter = Control.MOUSE_FILTER_STOP
			drop_top.visible = false
			drop_bottom.visible = false
		
		NOTIFICATION_DRAG_BEGIN:
			recent_btn.mouse_filter = Control.MOUSE_FILTER_PASS
			exit_btn.mouse_filter = Control.MOUSE_FILTER_PASS


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not data is RecentPopupButton:
		return false
	if data == self:
		return false
	
	if at_position.y < size.y / 2:
		drop_top.visible = true
		drop_bottom.visible = false
		drop_top_bool = true
	else:
		drop_top.visible = false
		drop_bottom.visible = true
		drop_top_bool = false
	
	return true


func _get_drag_data(at_position: Vector2) -> Variant:
	var copy: = self.duplicate()
	copy.rotation_degrees = 3.0
	copy.position = -at_position
	var tween = get_tree().create_tween()
	tween.tween_property(copy, "modulate:a", 0.5, 0.2)
	set_drag_preview(copy)
	return self


func  _drop_data(_at_position: Vector2, data: Variant) -> void:
	data = data as RecentPopupButton
	
	var recentList: VBoxContainer = data.get_parent()
	
	var index_temp = data.index
	data.index = self.index
	self.index = index_temp

	if data.index < 0:
		data.index = 0
	if !drop_top_bool:
		data.index += 1
	recentList.move_child(data, data.index)
	SingletonObject.reorder_recent_project(index_temp,data.index)
	if data.has_meta("project_path"):
		print(data.get_meta("project_path"))
	print("data dropped")



func _on_recent_btn_pressed() -> void:
	if has_meta("project_path"):
		SingletonObject.OpenRecentProject.emit(get_meta("project_path"))
