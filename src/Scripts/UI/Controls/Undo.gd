class_name undoMain
extends Node

var closed_chat_data: ChatHistory  # Store the data of the closed chat
var control: Control  # Store the tab control
var container: TabContainer  # Store the TabContainer

# Data to store deleted tabs for 5 minutes
var deleted_tabs = {}  # Dictionary to store deleted tabs and their data
#we use it for set up max time after what we remove item in deleted_tabs
var TimeForRemove = 180.0

# We store data from deleted tabs
func store_deleted_tab(tab: int, control_: Control, WhichWindow: String):
	var tab_name = control_.name
	var history = SingletonObject.ChatList[tab]
	
	var timer := Timer.new()
	add_child(timer)
	timer.wait_time = TimeForRemove
	timer.one_shot = true
	timer.connect("timeout", _on_timer_timeout)
	
	deleted_tabs[tab_name] = {
		"WhichWindow": WhichWindow,
		"tab": tab,
		"control": control_,
		"history": history,
		"timer": timer
	}
	deleted_tabs[tab_name]["timer"].start()
	
func store_deleted_tab_right(tab: int, control_: Control, WhichWindow: String):
	var tab_name = control_.name
	
	var timer := Timer.new()
	add_child(timer)
	timer.wait_time = TimeForRemove
	timer.one_shot = true
	timer.connect("timeout", _on_timer_timeout)
	
	deleted_tabs[tab_name] = {
		"WhichWindow": WhichWindow,
		"tab": tab,
		"control": control_,
		"timer": timer
	}
	
	deleted_tabs[tab_name]["timer"].start()
	
func store_deleted_tab_mid(tab: int, control_: Control, WhichWindow: String):
	var tab_name = control_.name
	
	var timer := Timer.new()
	add_child(timer)
	timer.wait_time = TimeForRemove
	timer.one_shot = true
	timer.connect("timeout", _on_timer_timeout)
	
	deleted_tabs[tab_name] = {
		"WhichWindow": WhichWindow,
		"tab": tab,
		"control": control_,
		"timer": timer
	}
	
	deleted_tabs[tab_name]["timer"].start()
	
func _on_timer_timeout():
	# Get the last deleted tab name 
	var last_deleted_tab_name = ""
	for tab_name in deleted_tabs.keys():
		last_deleted_tab_name = tab_name
		break  # Break after getting the first key

	# Access the data associated with the timer
	if last_deleted_tab_name in deleted_tabs:
		var deleted_tab_data = deleted_tabs[last_deleted_tab_name]
		
		# Get the control from the deleted tab data
		var control_to_delete = deleted_tab_data["control"]
		
		# Remove the tab data from the dictionary
		deleted_tabs.erase(last_deleted_tab_name)
		
		# Remove the control from the scene
		control_to_delete.queue_free()
