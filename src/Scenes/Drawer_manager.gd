extends Control
class_name Drawer_manager

var data_path: String = "user://drawer_data.json"
var last_saved_data: Dictionary = {}  # Holds the last saved data for comparison

func _ready() -> void:
	for i in 3:
		if $"../../../../../../../.." != null:
			$"../../../../../../../..".connect("openDrawerNotes",_render_drawer)
			break
			
func _on_save_data_pressed() -> void:
	save_notes(data_path)

func save_notes(path: String = "") -> void:
	var notes_data = serialize_notes()
	
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		if file:
			file.store_line(JSON.stringify(notes_data, "\t"))
			file.close()
			last_saved_data = notes_data  # Update last saved data
			print("Notes saved successfully to: ", path)
		else:
			push_error("Failed to save notes to ", path, ". Error: ", FileAccess.get_open_error())

func load_notes(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_warning("File does not exist: ", path)
		return
	
	var file = FileAccess.open(path, FileAccess.READ)
	if file:
		var json_text = file.get_as_text()
		file.close()
		
		var json = JSON.parse_string(json_text)
		if json is Dictionary:
			last_saved_data = json  # Store loaded data for comparison
			deserialize_notes(json)
		else:
			push_error("Failed to parse JSON data from ", path)
	else:
		push_error("Failed to open file ", path, ". Error: ", FileAccess.get_open_error())

# New function to get current data from memory
func get_current_data() -> Dictionary:
	return serialize_notes()

# New function to get saved data from file
func get_saved_data(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("File does not exist: ", path)
		return {}
	
	var file = FileAccess.open(path, FileAccess.READ)
	if file:
		var json_text = file.get_as_text()
		file.close()
		
		var json = JSON.parse_string(json_text)
		if json is Dictionary:
			return json
		else:
			push_error("Failed to parse JSON data from ", path)
			return {}
	else:
		push_error("Failed to open file ", path, ". Error: ", FileAccess.get_open_error())
		return {}

func serialize_notes() -> Dictionary:
	var notes_data: Array[Dictionary] = []
	
	for thread in SingletonObject.DrawerThreadList:
		var thread_data = {
			"ThreadId": thread.ThreadId,
			"ThreadName": thread.ThreadName,
			"MemoryItemList": []
		}
		
		for memory_item in thread.MemoryItemList:
			var memory_data = {
				"UUID": memory_item.UUID,
				"Enabled": memory_item.Enabled,
				"File": memory_item.File,
				"Locked": memory_item.Locked,
				"Title": memory_item.Title,
				"Content": memory_item.Content,
				"Type": memory_item.Type,
				"ContentType": memory_item.ContentType,
				"ImageCaption": memory_item.ImageCaption,
				"Visible": memory_item.Visible,
				"Pinned": memory_item.Pinned,
				"Order": memory_item.Order,
				"OwningThread": memory_item.OwningThread,
				"Expanded": memory_item.Expanded,
				"LastYSize": memory_item.LastYSize
			}
			
			# Handle image data
			if memory_item.Type == SingletonObject.note_type.IMAGE and memory_item.MemoryImage:
				var image = memory_item.MemoryImage
				var buffer = image.save_png_to_buffer()
				memory_data["ImageData"] = Marshalls.raw_to_base64(buffer)
			
			# Handle audio data - only save if it's a WAV or MP3
			if memory_item.Type == SingletonObject.note_type.AUDIO and memory_item.Audio:
				if memory_item.Audio is AudioStreamWAV:
					memory_data["AudioFormat"] = "wav"
					memory_data["AudioData"] = Marshalls.raw_to_base64(memory_item.Audio.data)
					# Save additional WAV properties
					memory_data["AudioMixRate"] = memory_item.Audio.mix_rate
					memory_data["AudioStereo"] = memory_item.Audio.stereo
					memory_data["AudioFormatEnum"] = memory_item.Audio.format
				elif memory_item.Audio is AudioStreamMP3:
					memory_data["AudioFormat"] = "mp3"
					memory_data["AudioData"] = Marshalls.raw_to_base64(memory_item.Audio.data)
					# Save additional MP3 properties
					memory_data["AudioBPM"] = memory_item.Audio.bpm
					memory_data["AudioBeatCount"] = memory_item.Audio.beat_count
					memory_data["AudioBarBeats"] = memory_item.Audio.bar_beats
					memory_data["AudioLoop"] = memory_item.Audio.loop
					memory_data["AudioLoopOffset"] = memory_item.Audio.loop_offset
				# Skip OGG as it's more complex to serialize
			
			thread_data["MemoryItemList"].append(memory_data)
		
		notes_data.append(thread_data)
	
	return {
		"version": 1,
		"last_updated": Time.get_datetime_string_from_system(),
		"notes": notes_data,
		"note_count": notes_data.size()
	}

func deserialize_notes(data: Dictionary) -> void:
	if not data.has("notes"):
		push_error("Invalid data format - missing 'notes' key")
		return
	
	# Clear existing data
	SingletonObject.DrawerThreadList.clear()
	
	for thread_data in data["notes"]:
		var thread = MemoryThread.new()
		thread.ThreadId = thread_data.get("ThreadId", str(randi()))
		thread.ThreadName = thread_data.get("ThreadName", "Thread " + str(randi() % 1000))
		
		if thread_data.has("MemoryItemList"):
			for memory_data in thread_data["MemoryItemList"]:
				var memory_item = MemoryItem.new(thread.ThreadId)
				memory_item.UUID = memory_data.get("UUID", str(randi()))
				memory_item.Enabled = memory_data.get("Enabled", false)
				memory_item.File = memory_data.get("File", "")
				memory_item.Locked = memory_data.get("Locked", false)
				memory_item.Title = memory_data.get("Title", "")
				memory_item.Content = memory_data.get("Content", "")
				memory_item.Type = memory_data.get("Type", 0)
				memory_item.ContentType = memory_data.get("ContentType", "text")
				memory_item.ImageCaption = memory_data.get("ImageCaption", "")
				memory_item.Visible = memory_data.get("Visible", true)
				memory_item.Pinned = memory_data.get("Pinned", false)
				memory_item.Order = memory_data.get("Order", 0)
				memory_item.OwningThread = memory_data.get("OwningThread", thread.ThreadId)
				memory_item.Expanded = memory_data.get("Expanded", true)
				memory_item.LastYSize = memory_data.get("LastYSize", 100.0)
				
				# Handle image data
				if memory_data.has("ImageData"):
					var buffer = Marshalls.base64_to_raw(memory_data["ImageData"])
					var image = Image.new()
					if image.load_png_from_buffer(buffer) == OK:
						memory_item.MemoryImage = image
				
				# Handle audio data
				if memory_data.has("AudioData") and memory_data.has("AudioFormat"):
					var buffer = Marshalls.base64_to_raw(memory_data["AudioData"])
					match memory_data["AudioFormat"]:
						"wav":
							var audio = AudioStreamWAV.new()
							audio.data = buffer
							# Restore WAV properties
							audio.mix_rate = memory_data.get("AudioMixRate", 44100)
							audio.stereo = memory_data.get("AudioStereo", true)
							audio.format = memory_data.get("AudioFormatEnum", AudioStreamWAV.FORMAT_16_BITS)
							memory_item.Audio = audio
						"mp3":
							var audio = AudioStreamMP3.new()
							audio.data = buffer
							# Restore MP3 properties
							audio.bpm = memory_data.get("AudioBPM", 125.0)
							audio.beat_count = memory_data.get("AudioBeatCount", 4)
							audio.bar_beats = memory_data.get("AudioBarBeats", 4)
							audio.loop = memory_data.get("AudioLoop", false)
							audio.loop_offset = memory_data.get("AudioLoopOffset", 0.0)
							memory_item.Audio = audio
						# OGG is not handled here as per your request
				
				thread.MemoryItemList.append(memory_item)
		
		SingletonObject.DrawerThreadList.append(thread)
	
	# Force UI update
	if SingletonObject.DrawerTab:
		SingletonObject.DrawerTab.clear_all_tabs()
		SingletonObject.DrawerTab.render_threads()

func _render_drawer() -> void:
	load_notes(data_path)
	
#func _notification(what):
	#if what == NOTIFICATION_WM_CLOSE_REQUEST and $"..".close_requested:
		## Compare current data with last saved data
		#var current_data = get_current_data()
		#var has_changes = not compare_data(current_data, last_saved_data)
		#
		#if has_changes:
			#$"../CloseActions".popup_centered()
		#else:
			#$"..".hide()

# New function to compare two data sets
func compare_data(data1: Dictionary, data2: Dictionary) -> bool:
	# Simple comparison - you might want to make this more sophisticated
	# For example, by comparing only the relevant fields
	
	# Quick check for empty data
	if data1.is_empty() or data2.is_empty():
		return false
	
	# Compare basic structure
	if data1.get("note_count", 0) != data2.get("note_count", 0):
		return false
	
	# Compare each thread and memory item
	if data1.has("notes") and data2.has("notes"):
		var notes1 = data1["notes"]
		var notes2 = data2["notes"]
		
		if notes1.size() != notes2.size():
			return false
			
		for i in notes1.size():
			var thread1 = notes1[i]
			var thread2 = notes2[i]
			
			# Compare thread properties
			if thread1.get("ThreadId") != thread2.get("ThreadId") or \
			   thread1.get("ThreadName") != thread2.get("ThreadName"):
				return false
				
			# Compare memory items
			var items1 = thread1.get("MemoryItemList", [])
			var items2 = thread2.get("MemoryItemList", [])
			
			if items1.size() != items2.size():
				return false
				
			for j in items1.size():
				var item1 = items1[j]
				var item2 = items2[j]
				
				# Compare key properties of memory items
				if item1.get("UUID") != item2.get("UUID") or \
				   item1.get("Title") != item2.get("Title") or \
				   item1.get("Content") != item2.get("Content") or \
				   item1.get("Type") != item2.get("Type"):
					return false
	
	return true

func _on_save_pressed() -> void:
	save_notes(data_path)
	$"..".hide()
	$"../CloseActions".hide()

func _on_close_pressed() -> void:
	$"../CloseActions".hide()

func _on_exit_pressed() -> void:
	$"../CloseActions".hide()
	$"..".hide()


func _on_add_note_pressed() -> void:
	%CreateNewNote.popup_centered()
	%CreateNewNote.isDrawer = true


func _on_add_shelf_pressed() -> void:
	%NewThreadPopup.popup_centered()
	%NewThreadPopup.isDrawer = true
