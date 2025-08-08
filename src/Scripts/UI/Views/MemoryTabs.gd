class_name MemoryTabs
extends BaseTabContainer

@onready var tcThreads: MemoryTabs = %tcThreads
@onready var tcThreadsDrawer = %tcThreadsDrawer
static var vboxMemoryList: = preload("res://Scripts/UI/Controls/vboxMemoryList.gd")

# Override abstract methods
func get_thread_list() -> Array[MemoryThread]:
	return SingletonObject.ThreadList

func get_tab_container() -> TabContainer:
	return tcThreads

func get_vbox_scene():
	return vboxMemoryList

func create_vbox_memory_list(thread: MemoryThread):
	return vboxMemoryList.new(self, thread, false)

## Function:
# attach_file creates a memory item/note from a file.  It can detect file type
func attach_file(the_file: String):
	# Check if the file exists
	var file = FileAccess.open(the_file, FileAccess.READ)
	if file == null:
		SingletonObject.ErrorDisplay("File Error", "The file could not be opened.")
		return
		
	var file_ext = the_file.get_extension().to_lower()
	
	# Determine the file type
	@warning_ignore("unused_variable")
	var file_type = ""
	var content = ""
	var content_type = ""
	var type
	var title = the_file.get_file()
	
	# Get the active thread
	if (SingletonObject.ThreadList == null) or current_tab < 0:
		create_new_notes_tab()
	var active_thread: MemoryThread = SingletonObject.ThreadList[self.current_tab]
	
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.File = the_file # associate the file with the new memory item
	
	if _is_text_file(the_file):
		type = SingletonObject.note_type.TEXT
		content_type = "text/plain"
		content = file.get_as_text()
	elif file_ext in SingletonObject.supported_image_formats:
		file_type = "image"
		type = SingletonObject.note_type.IMAGE
		var file_data = file.get_buffer(file.get_length())
		var image: Image = Image.new()
		var err: Error = OK
		match file_ext:
			"svg":
				err = image.load_svg_from_buffer(file_data)
			"jpeg", "jpg":
				err = image.load_jpg_from_buffer(file_data)
			"png":
				err = image.load_png_from_buffer(file_data)
			"bmp":
				err = image.load_bmp_from_buffer(file_data)
			"webp":
				err = image.load_webp_from_buffer(file_data)
			"tga":
				err = image.load_tga_from_buffer(file_data)
		if err == OK:
			new_memory.MemoryImage = image
			content = Marshalls.raw_to_base64(file_data)
		else:
			printerr("Error loading image file %s" % file)
			SingletonObject.ErrorDisplay("Error loading image", "An error occurred while trying to load the image file %s" % file)
		content_type = "image/%s" % file_ext
	elif file_ext in SingletonObject.supported_video_formats:
		file_type = "video"
		type = SingletonObject.note_type.VIDEO
		content = the_file
		content_type = "video/%s" % file_ext
	elif file_ext in SingletonObject.supported_audio_formats:
		file_type = "audio"
		type = SingletonObject.note_type.AUDIO
		var buffer = file.get_buffer(file.get_length())
		match file_ext:
			"mp3":
				var mp3AudioStream = AudioStreamMP3.new()
				mp3AudioStream.data = buffer
				new_memory.Audio = mp3AudioStream
			"wav":
				var wavAudioStream = AudioStreamWAV.load_from_buffer(buffer)
				new_memory.Audio = wavAudioStream
			"ogg":
				var oggAudioStream = AudioStreamOggVorbis.load_from_file(the_file)
				new_memory.Audio = oggAudioStream
		content = Marshalls.raw_to_base64(buffer)
		content_type = "audio/%s" % file_ext
	elif _is_binary_file(the_file):
		# Generic binary file handling
		type = SingletonObject.note_type.BINARY
		content_type = "application/octet-stream"
		content = Marshalls.raw_to_base64(file.get_buffer(file.get_length()))
	else:
		# Fallback to text handling
		type = SingletonObject.note_type.TEXT
		content_type = "text/plain"
		content = file.get_as_text()

	# Create a new memory item
	new_memory.Enabled = true
	new_memory.Title = title
	new_memory.Content = content
	new_memory.ContentType = content_type
	new_memory.Type = type
	new_memory.Visible = true
	
	# Append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)

	file.close()

# Helper function to check if a file is binary (opposite of text file)
func _is_binary_file(file_path: String) -> bool:
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return false  # Can't open file, assume it's not binary
	
	# Read first 1024 bytes to check
	var buffer: = file.get_buffer(1024)
	if buffer.is_empty(): 
		return false  # Empty file is not binary
	
	for byte in buffer:
		# Binary files typically contain control characters (0-8, 14-31) 
		# except for common whitespace characters (\t, \n, \r)
		if byte < 9 or (byte > 13 and byte < 32):
			file.close()
			return true
	
	file.close()
	return false
	
# helper func to check if the file is text
func _is_text_file(file_path: String) -> bool:
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return false

	var is_text: bool = false
	var buffer: = file.get_buffer(1024)  # Read the first 1024 bytes
	if buffer.is_empty(): return true
	for byte in buffer:
		# Check for non-text characters (control characters outside of \t, \n, \r)
		if byte < 9 or (byte > 13 and byte < 32):
			is_text = false
			break
		else:
			is_text = true

	file.close()
	return is_text

func _on_new_pressed():
	%NewThreadPopup.isDrawer = false
	open_threads_popup()

# Called when the node enters the scene tree for the first time.
func _ready():
	get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(self))
	%tcThreadsDrawer.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(%tcThreadsDrawer))
		
	# tab bar need mouse_filter set to pass to allow the tab container to catch drag event and call _can_drop_data
	get_tab_bar().mouse_filter = MOUSE_FILTER_PASS

	SingletonObject.ThreadList = []
	SingletonObject.NotesTab = self
	SingletonObject.AttachNoteFile.connect(self.attach_file)
	SingletonObject.create_notes_tab.connect(_on_btn_create_thread_pressed)
	# Don't call render_threads() - tabs will be created as needed

func _on_drawer_tab_clicked(tab: int): 
	_on_tab_clicked(tab, %tcThreadsDrawer)
