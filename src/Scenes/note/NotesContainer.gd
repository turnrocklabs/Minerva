class_name NotesContainer
extends TabContainer

## Creates a new tab with given name.[br]
## If the name is already taken godot will autimatically assing a new one.[br]
## Retuns the scroll container added as the new tab.
func create_tab(tab_name: String = "Notes") -> Control:
    if tab_name.is_empty():
        tab_name = "Notes"

    var scroll: = ScrollContainer.new()

    var vbox: = VBoxContainer.new()
    vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    
    scroll.add_child(vbox)
    scroll.name = tab_name

    # force readable name
    add_child(scroll, true)

    return scroll


## Adds the provided [parameter note] to the [parameter tab_idx] tab.[br]
## If [parameter tab_idx] is -1, currently selected tab is used, or it fails if no tab is selected.[br]
## If [parameter force] is true, and appropriate tab wasn't found, new one will be created.[br] 
## Returns true on success.
func add_note(note: Note, tab_idx: int = -1, force: = true) -> bool:

    if tab_idx == -1:
        tab_idx = current_tab

    # if still -1 there is no selected tab to add to
    if tab_idx == -1:
        if force:
            var created_scroll: = create_tab()
            var vbox_ = created_scroll.get_child(0)
            if not vbox_:
                push_error("Couldn't get the VBoxContainer to add the note to")

            vbox_.add_child(note)

            return true
        
        return false

    var current_scroll: ScrollContainer = get_tab_control(current_tab)
    var vbox = current_scroll.get_child(0)

    if not vbox:
        push_error("Couldn't get the VBoxContainer to add the note to")

    vbox.add_child(note)

    return true

## Returns an array of notes in the specified tab[br].
## If not tab is specified ([-1]) returns notes from the currently selected tab or empty array.
func get_notes(tab_idx: = -1) -> Array[Note]:
    tab_idx = tab_idx if tab_idx != -1 else current_tab

    if tab_idx == -1: return []

    var current_scroll: ScrollContainer = get_tab_control(current_tab)
    var vbox = current_scroll.get_child(0)

    if not vbox:
        push_error("Couldn't get the VBoxContainer to get the notes")
        return []
    
    var notes: Array[Note] = []

    for child in vbox.get_children():
        if child is Note:
            notes.append(child)

    return notes

## Makes all notes in the specified or currently active tab.
func show_notes(tab_idx: = -1):
    tab_idx = tab_idx if tab_idx != -1 else current_tab
    if tab_idx == -1: return

    for note in get_notes(tab_idx):
        note.visible = true

## Hides all notes in the specified or currently active tab.
func hide_notes(tab_idx: = -1):
    tab_idx = tab_idx if tab_idx != -1 else current_tab
    if tab_idx == -1: return

    for note in get_notes(tab_idx):
        note.visible = true


func serialize() -> Array[Array]:
    var data: Array[Array]

    for i in range(get_tab_count()):
        var notes_data: Array[Dictionary]
        
        var notes: = get_notes(i)

        for note in notes:
            notes_data.append(note.serialize())



    return data

func deserialize(notes_data: Array) -> void:

    # print(notes_data)

    for tab_data in notes_data:
        var tab_title: String = tab_data.get("ThreadName")
        create_tab(tab_title)

        for mem_item_data in tab_data.get("MemoryItemList", []):
            Note.deserialize(mem_item_data)