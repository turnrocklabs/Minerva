class_name AutocoderFileTree
extends PanelContainer

## Displays generated files in a tree structure with status indicators
## Files can be clicked to view their content

signal file_selected(file_path: String, file_data: Dictionary)
signal download_requested(uri: String, filename: String)

enum FileStatus {
	ADDED,
	MODIFIED,
	DELETED,
	UNKNOWN
}

const STATUS_COLORS = {
	FileStatus.ADDED: Color(0.4, 0.9, 0.4),    # Green
	FileStatus.MODIFIED: Color(0.9, 0.7, 0.3), # Orange
	FileStatus.DELETED: Color(0.9, 0.4, 0.4),  # Red
	FileStatus.UNKNOWN: Color(0.7, 0.7, 0.7)   # Gray
}

const STATUS_ICONS = {
	FileStatus.ADDED: "+",
	FileStatus.MODIFIED: "~",
	FileStatus.DELETED: "-",
	FileStatus.UNKNOWN: "?"
}

@onready var _header_label: Label = %HeaderLabel
@onready var _file_count_label: Label = %FileCountLabel
@onready var _tree: Tree = %FileTree
@onready var _empty_label: Label = %EmptyLabel
@onready var _download_archive_button: Button = %DownloadArchiveButton
@onready var _download_patch_button: Button = %DownloadPatchButton

var _files: Dictionary = {}  # path -> {status, size, artifact_uri, etc}
var _tree_items: Dictionary = {}  # path -> TreeItem
var _archive_uri: String = ""
var _patch_uri: String = ""


func _ready() -> void:
	if _tree:
		_tree.columns = 3
		_tree.set_column_title(0, "File")
		_tree.set_column_title(1, "Status")
		_tree.set_column_title(2, "Size")
		_tree.set_column_expand(0, true)
		_tree.set_column_expand(1, false)
		_tree.set_column_expand(2, false)
		_tree.set_column_custom_minimum_width(1, 80)
		_tree.set_column_custom_minimum_width(2, 80)
		_tree.hide_root = true
		_tree.item_selected.connect(_on_item_selected)
		_tree.item_activated.connect(_on_item_activated)
	
	if _download_archive_button:
		_download_archive_button.pressed.connect(_on_download_archive_pressed)
	
	if _download_patch_button:
		_download_patch_button.pressed.connect(_on_download_patch_pressed)
	
	_update_empty_state()


func set_files(files: Dictionary, archive_uri: String = "", patch_uri: String = "") -> void:
	"""Set the files to display in the tree
	
	files format: {
		"path/to/file.gd": {
			"path": "path/to/file.gd",
			"status": "added" | "modified" | "deleted",
			"size": 1234,
			"artifact_uri": "artifact://..."
		}
	}
	"""
	_files = files
	_archive_uri = archive_uri
	_patch_uri = patch_uri
	_rebuild_tree()
	_update_download_buttons()


func add_file(file_path: String, file_data: Dictionary) -> void:
	"""Add or update a single file in the tree"""
	_files[file_path] = file_data
	_rebuild_tree()


func clear() -> void:
	"""Clear all files from the tree"""
	_files.clear()
	_tree_items.clear()
	_archive_uri = ""
	_patch_uri = ""
	if _tree:
		_tree.clear()
	_update_empty_state()
	_update_download_buttons()


func _rebuild_tree() -> void:
	"""Rebuild the tree from the files dictionary"""
	if not _tree:
		return
	
	_tree.clear()
	_tree_items.clear()
	
	var root = _tree.create_item()
	
	# Sort files by path
	var sorted_paths = _files.keys()
	sorted_paths.sort()
	
	# Build folder structure
	var folders: Dictionary = {}  # folder_path -> TreeItem
	
	for file_path in sorted_paths:
		var file_data = _files[file_path]
		var parts = str(file_path).split("/")
		
		# Create folder hierarchy
		var current_path = ""
		var parent_item = root
		
		for i in range(parts.size() - 1):
			var part = parts[i]
			current_path = part if current_path.is_empty() else current_path + "/" + part
			
			if not folders.has(current_path):
				var folder_item = _tree.create_item(parent_item)
				folder_item.set_text(0, "📁 " + part)
				folder_item.set_metadata(0, {"type": "folder", "path": current_path})
				folder_item.collapsed = false
				folders[current_path] = folder_item
			
			parent_item = folders[current_path]
		
		# Create file item
		var filename = parts[parts.size() - 1]
		var file_item = _tree.create_item(parent_item)
		
		var status = _parse_status(str(file_data.get("status", "unknown")))
		var status_icon = STATUS_ICONS.get(status, "?")
		var status_color = STATUS_COLORS.get(status, Color.WHITE)
		
		# Column 0: File icon + name
		var file_icon = _get_file_icon(filename)
		file_item.set_text(0, file_icon + " " + filename)
		
		# Column 1: Status
		file_item.set_text(1, status_icon + " " + _status_to_string(status))
		file_item.set_custom_color(1, status_color)
		
		# Column 2: Size
		var size_bytes = file_data.get("size", 0)
		file_item.set_text(2, _format_size(size_bytes))
		
		# Store metadata for click handling
		file_item.set_metadata(0, {"type": "file", "path": file_path, "data": file_data})
		_tree_items[file_path] = file_item
	
	_update_empty_state()
	_update_file_count()


func _parse_status(status_str: String) -> FileStatus:
	match status_str.to_lower():
		"added", "add", "new", "a":
			return FileStatus.ADDED
		"modified", "modify", "changed", "m":
			return FileStatus.MODIFIED
		"deleted", "delete", "removed", "d":
			return FileStatus.DELETED
		_:
			return FileStatus.UNKNOWN


func _status_to_string(status: FileStatus) -> String:
	match status:
		FileStatus.ADDED:
			return "Added"
		FileStatus.MODIFIED:
			return "Modified"
		FileStatus.DELETED:
			return "Deleted"
		_:
			return "Unknown"


func _get_file_icon(filename: String) -> String:
	var ext = filename.get_extension().to_lower()
	match ext:
		"gd":
			return "📜"  # GDScript
		"tscn", "scn":
			return "🎬"  # Scene
		"tres", "res":
			return "📦"  # Resource
		"png", "jpg", "jpeg", "svg", "webp":
			return "🖼️"  # Image
		"wav", "ogg", "mp3":
			return "🔊"  # Audio
		"json":
			return "📋"  # JSON
		"cfg", "ini", "toml", "yaml", "yml":
			return "⚙️"  # Config
		"md", "txt", "rst":
			return "📝"  # Text
		"py":
			return "🐍"  # Python
		"js", "ts":
			return "📜"  # JavaScript/TypeScript
		"sh", "bash":
			return "💻"  # Shell
		"godot":
			return "🎮"  # Godot project
		_:
			return "📄"  # Generic file


func _format_size(bytes: int) -> String:
	if bytes < 0:
		return "?"
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / (1024.0 * 1024.0))


func _update_empty_state() -> void:
	var has_files = _files.size() > 0
	if _tree:
		_tree.visible = has_files
	if _empty_label:
		_empty_label.visible = not has_files


func _update_file_count() -> void:
	if _file_count_label:
		var file_count = _files.size()
		_file_count_label.text = "%d file%s" % [file_count, "s" if file_count != 1 else ""]


func _update_download_buttons() -> void:
	if _download_archive_button:
		_download_archive_button.disabled = _archive_uri.is_empty()
		_download_archive_button.tooltip_text = _archive_uri if not _archive_uri.is_empty() else "No archive available"
	
	if _download_patch_button:
		_download_patch_button.disabled = _patch_uri.is_empty()
		_download_patch_button.tooltip_text = _patch_uri if not _patch_uri.is_empty() else "No patch available"


func _on_item_selected() -> void:
	var selected = _tree.get_selected()
	if not selected:
		return
	
	var metadata = selected.get_metadata(0)
	if not metadata or not (metadata is Dictionary):
		return
	
	if metadata.get("type") == "file":
		var file_path = str(metadata.get("path", ""))
		var file_data = metadata.get("data", {})
		file_selected.emit(file_path, file_data)


func _on_item_activated() -> void:
	# Double-click - same as single click for now
	_on_item_selected()


func _on_download_archive_pressed() -> void:
	if not _archive_uri.is_empty():
		download_requested.emit(_archive_uri, "archive.tar.gz")


func _on_download_patch_pressed() -> void:
	if not _patch_uri.is_empty():
		download_requested.emit(_patch_uri, "changes.patch")
