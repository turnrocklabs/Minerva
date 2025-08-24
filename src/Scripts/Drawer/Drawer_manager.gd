extends Control
class_name Drawer_manager

# var data_path: String = "user://drawer_data.json"

# func _ready() -> void:
# 	# Load data on startup
# 	load_drawer_data()
	
# 	# Connect save signal
# 	SingletonObject.connect("drawer_save_data", save_drawer_data)

# ## Main save function - called by signal
# func save_drawer_data() -> void:
# 	print("\n\n")
# 	print("SAVE DRAWER NOTES")
# 	print_stack()

# 	if SingletonObject.DrawerTab.lock:
# 		return

# 	var serialized_data = serialize_drawer_data()
# 	write_data_to_file(serialized_data)

# ## Serialize drawer threads and notes to dictionary
# func serialize_drawer_data() -> Dictionary:
# 	var drawer_data: Array[Dictionary] = []
	
# 	for thread in SingletonObject.DrawerThreadList:
# 		var thread_data = {
# 			"ThreadId": thread.ThreadId,
# 			"ThreadName": thread.ThreadName,
# 			"MemoryItemList": serialize_memory_items(thread.MemoryItemList)
# 		}
# 		drawer_data.append(thread_data)
	
# 	return {
# 		"version": 1,
# 		"timestamp": Time.get_datetime_string_from_system(),
# 		"drawer_threads": drawer_data
# 	}

# ## Serialize array of memory items
# func serialize_memory_items(memory_items: Array[MemoryItem]) -> Array[Dictionary]:
# 	var items_data: Array[Dictionary] = []
# 	print("Created empty items_data array")
	
# 	for i in range(memory_items.size()):
# 		var item = memory_items[i]
# 		print("Processing item ", i, ": ", item.Title)
		
# 		var item_data = {
# 			"UUID": item.UUID,
# 			"Title": item.Title,
# 			"Content": item.Content,
# 			"Type": item.Type,
# 			"ContentType": item.ContentType,
# 			"Enabled": item.Enabled,
# 			"Visible": item.Visible,
# 			"Order": item.Order,
# 			"OwningThread": item.OwningThread,
# 			"isDrawer": item.isDrawer
# 		}
# 		print("Created basic item_data with keys: ", item_data.keys())
		
# 		# Handle type-specific data
# 		match item.Type:
# 			SingletonObject.note_type.IMAGE:
# 				print("Processing IMAGE type")
# 				if item.MemoryImage:
# 					var buffer = item.MemoryImage.save_png_to_buffer()
# 					item_data["ImageData"] = Marshalls.raw_to_base64(buffer)
# 					item_data["ImageCaption"] = item.ImageCaption
# 					print("Added image data")
			
# 			SingletonObject.note_type.AUDIO:
# 				print("Processing AUDIO type")
# 				if item.Audio:
# 					if item.Audio is AudioStreamWAV:
# 						item_data["AudioFormat"] = "wav"
# 						item_data["AudioData"] = Marshalls.raw_to_base64(item.Audio.data)
# 						item_data["AudioMixRate"] = item.Audio.mix_rate
# 						item_data["AudioStereo"] = item.Audio.stereo
# 						item_data["AudioFormatEnum"] = item.Audio.format
# 						print("Added WAV audio data")
# 					elif item.Audio is AudioStreamMP3:
# 						item_data["AudioFormat"] = "mp3"
# 						item_data["AudioData"] = Marshalls.raw_to_base64(item.Audio.data)
# 						print("Added MP3 audio data")
# 			_:
# 				print("Processing TEXT or other type")
		
# 		items_data.append(item_data)
# 		print("items_data size after append: ", items_data.size())
	
# 	return items_data

# ## Write serialized data to file
# func write_data_to_file(data: Dictionary) -> void:
# 	var file = FileAccess.open(data_path, FileAccess.WRITE)
# 	if file:
# 		file.store_line(JSON.stringify(data, "\t"))
# 		file.close()
# 		print("Drawer data saved successfully")
# 	else:
# 		push_error("Failed to save drawer data: " + str(FileAccess.get_open_error()))

# ## Main load function
# func load_drawer_data() -> void:
# 	if not FileAccess.file_exists(data_path):
# 		print("No drawer data file found - starting fresh")
# 		return
	
# 	var data = read_data_from_file()
# 	if data.is_empty():
# 		return
		
# 	deserialize_drawer_data(data)

# ## Read and parse data from file
# func read_data_from_file() -> Dictionary:
# 	var file = FileAccess.open(data_path, FileAccess.READ)
# 	if not file:
# 		push_error("Failed to open drawer data file: " + str(FileAccess.get_open_error()))
# 		return {}
	
# 	var json_text = file.get_as_text()
# 	file.close()
	
# 	var json = JSON.parse_string(json_text)
# 	if not json is Dictionary:
# 		push_error("Invalid JSON in drawer data file")
# 		return {}
	
# 	return json

# ## Deserialize data and create UI
# func deserialize_drawer_data(data: Dictionary) -> void:
# 	if not data.has("drawer_threads"):
# 		print("No drawer threads found in data")
# 		return
	
# 	# Clear existing data and UI
# 	SingletonObject.DrawerThreadList.clear()
# 	if SingletonObject.DrawerTab:
# 		SingletonObject.DrawerTab.clear_all_tabs()
	
# 	# Load each thread
# 	for thread_data in data["drawer_threads"]:
# 		var thread = create_thread_from_data(thread_data)
# 		if thread:
# 			# Add to data model
# 			SingletonObject.DrawerThreadList.append(thread)
			
# 			# Create UI tab for this thread
# 			if SingletonObject.DrawerTab:
# 				SingletonObject.DrawerTab.setup_thread_container(thread)
				
# 				# THIS IS MISSING - trigger rendering of loaded notes
# 				SingletonObject.DrawerTab.memories_updated.emit(thread)

			

# ## Create a MemoryThread from serialized data
# func create_thread_from_data(thread_data: Dictionary) -> MemoryThread:
# 	var thread = MemoryThread.new()
# 	thread.ThreadId = thread_data.get("ThreadId", generate_thread_id())
# 	thread.ThreadName = thread_data.get("ThreadName", "Drawer Tab")
	
# 	# Load memory items
# 	if thread_data.has("MemoryItemList"):
# 		for item_data in thread_data["MemoryItemList"]:
# 			var memory_item = create_memory_item_from_data(item_data, thread.ThreadId)
# 			if memory_item:
# 				thread.MemoryItemList.append(memory_item)
	
# 	return thread

# ## Create a MemoryItem from serialized data
# func create_memory_item_from_data(item_data: Dictionary, thread_id: String) -> MemoryItem:
# 	var item = MemoryItem.new(thread_id)
	
# 	# Basic properties
# 	item.UUID = item_data.get("UUID", SingletonObject.generate_UUID())
# 	item.Title = item_data.get("Title", "")
# 	item.Content = item_data.get("Content", "")
# 	item.Type = item_data.get("Type", SingletonObject.note_type.TEXT)
# 	item.ContentType = item_data.get("ContentType", "text")
# 	item.Enabled = item_data.get("Enabled", false)
# 	item.Visible = item_data.get("Visible", true)
# 	item.Order = item_data.get("Order", 0)
# 	item.OwningThread = item_data.get("OwningThread", thread_id)
# 	item.isDrawer = item_data.get("isDrawer", true)
	
# 	# Handle type-specific data
# 	match item.Type:
# 		SingletonObject.note_type.IMAGE:
# 			if item_data.has("ImageData"):
# 				var buffer = Marshalls.base64_to_raw(item_data["ImageData"])
# 				var image = Image.new()
# 				if image.load_png_from_buffer(buffer) == OK:
# 					item.MemoryImage = image
# 			item.ImageCaption = item_data.get("ImageCaption", "")
		
# 		SingletonObject.note_type.AUDIO:
# 			if item_data.has("AudioData") and item_data.has("AudioFormat"):
# 				var buffer = Marshalls.base64_to_raw(item_data["AudioData"])
# 				match item_data["AudioFormat"]:
# 					"wav":
# 						var audio = AudioStreamWAV.new()
# 						audio.data = buffer
# 						audio.mix_rate = item_data.get("AudioMixRate", 44100)
# 						audio.stereo = item_data.get("AudioStereo", true)
# 						audio.format = item_data.get("AudioFormatEnum", AudioStreamWAV.FORMAT_16_BITS)
# 						item.Audio = audio
# 					"mp3":
# 						var audio = AudioStreamMP3.new()
# 						audio.data = buffer
# 						item.Audio = audio
	
# 	return item

# ## Generate a unique thread ID
# func generate_thread_id() -> String:
# 	return "drawer_thread_" + str(Time.get_unix_time_from_system()) + "_" + str(randi())

# ## UI Event Handlers
# func _on_add_note_pressed() -> void:
# 	%CreateNewNote.popup_centered()
# 	%CreateNewNote.isDrawer = true

# func _on_add_shelf_pressed() -> void:
# 	%NewThreadPopup.popup_centered()
# 	%NewThreadPopup.isDrawer = true

# func _on_save_pressed() -> void:
# 	save_drawer_data()
# 	$"..".hide()
# 	$"../CloseActions".hide()

# func _on_close_pressed() -> void:
# 	$"../CloseActions".hide()

# func _on_exit_pressed() -> void:
# 	$"../CloseActions".hide()
# 	$"..".hide()
