extends Node

#region Notes
var ThreadList: Array[MemoryThread]:
	set(value):
		# save_state(false)
		ThreadList = value

var NotesTab: MemoryTabs

func initialize_notes(threads: Array[MemoryThread] = []):
	ThreadList = threads
	
	NotesTab.render_threads()
	pass

signal AttachNoteFile(file_path:String)

#endregion Notes

#region Chats
var ChatList: Array[ChatHistory]:
	set(value):
		# save_state(false)
		ChatList = value
		print(value)

var last_tab_index: int
# var active_chatindex: int just use Chats.current_tab
var Provider
var Chats: ChatPane

func initialize_chats(provider, _chats: ChatPane, chat_histories: Array[ChatHistory] = []):
	ChatList = chat_histories
	Provider = provider
	
	Chats = _chats
	Chats.clear_all_chats()
	
	# last_tab_index = 0
	# active_chatindex = 0

	for ch in chat_histories:
		Chats.render_history(ch)

#endregion Chats

#region Editor

@onready var editor_container: EditorContainer = $"/root/RootControl/VBoxRoot/MainUI/HSplitContainer/HSplitContainer2/MiddlePane/VBoxContainer/vboxEditorMain"

#endregion

#region Common UI Tasks

@onready var main_ui = $"/root/RootControl/VBoxRoot/MainUI"

###
# Create a common error display system that will popup an error and show
# and show the message
var errorPopup: PopupPanel
var errorTitle: Label
var errorText: Label
func ErrorDisplay(error_title:String, error_message: String):
	errorTitle.text = error_title
	errorText.text = error_message
	errorPopup.popup_centered()
	pass

@onready var _default_zoom = $"/root/RootControl".theme.default_font_size
func zoom_ui(factor: int):
	var theme = $"/root/RootControl".theme
	if theme.has_default_font_size():
		theme.default_font_size += factor
	else:
		theme.default_font_size = ThemeDB.fallback_font_size + factor

func reset_zoom():
	$"/root/RootControl".theme.default_font_size = _default_zoom

#endregion Common UI Tasks

#region API Consumer
enum API_PROVIDER {GOOGLE, OPENAI, ANTHROPIC}

@onready var preferences_popup: PreferencesPopup = $"/root/RootControl/PreferencesPopup"

#endregion API Consumer

#region Project Management
signal NewProject
signal OpenProject
signal SaveProject
signal SaveProjectAs
signal CloseProject
signal RedrawAll

var saved_state = true:
	set(value):
		print("Saved state changed (%s)" % value)
		saved_state = value


func save_state(state: bool): saved_state = state

#endregion Project Management
