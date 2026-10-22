class_name PluginGenerationStore
extends RefCounted
## Immutable source archives and a crash-recoverable selector. Cache slots are
## disposable; neither archives nor selectors contain plugin user data.

const Atomic := preload("res://Scripts/Services/Plugins/AtomicFile.gd")
const MAX_BYTES := 32 * 1024 * 1024
const HOST_PATHS: Array[String] = [
	"res://Scripts/Services/Plugins/AtomicFile.gd",
	"res://Scripts/Services/Documents/DocumentBuffer.gd",
	"res://Scripts/Services/Plugins/MinervaPluginPanel.gd",
	"res://Scripts/Services/Annotations/AnnotationV2Schema.gd",
	"res://Scripts/Services/Annotations/BuiltinKinds.gd",
	"res://Scripts/UI/Controls/responsive_container.gd",
]

var directory: String
var _error: String = ""
static var _profile_path: String = ""
static var _profile_real_path: String = ""


func _init(plugin_id: String, generations_root: String = "user://plugins/.generations") -> void:
	var rx := RegEx.new()
	rx.compile("^[a-z][a-z0-9_]*$")
	if rx.search(plugin_id) == null:
		_error = "Invalid plugin generation identifier"
		return
	directory = ProjectSettings.globalize_path(generations_root).path_join(plugin_id)


func selector_path() -> String:
	return directory.path_join("selector.json")


func slot_path(slot: String) -> String:
	return directory.path_join(slot) if slot in ["A", "B"] and not directory.is_empty() else ""


func error_message() -> String:
	return _error


func _fail(message: String) -> Dictionary:
	_error = message
	return {"ok": false, "error": message}


## Capture once, before replacing installed files. Refuse symlinks, so an
## archive never follows a plugin-controlled path into another plugin or data.
func capture(source_directory: String) -> Dictionary:
	if directory.is_empty():
		return _fail("Invalid generation store")
	var files: Dictionary = {}
	var result := _capture_directory(source_directory, "", files)
	if not result.get("ok", false):
		return result
	return bundle(files)


func _capture_directory(source: String, relative: String, files: Dictionary) -> Dictionary:
	var dir := DirAccess.open(source.path_join(relative))
	if dir == null:
		return _fail("Cannot read plugin sources: " + relative)
	for name: String in dir.get_directories():
		if dir.is_link(name):
			return _fail("Plugin source symlink refused: " + name)
		if name.begins_with("."):
			continue
		var nested := _capture_directory(source, relative.path_join(name), files)
		if not nested.get("ok", false):
			return nested
	for name: String in dir.get_files():
		if dir.is_link(name):
			return _fail("Plugin source symlink refused: " + name)
		if name.ends_with(".uid") or name.ends_with(".import") or name.begins_with("."):
			continue
		var path := relative.path_join(name)
		var file := FileAccess.open(source.path_join(path), FileAccess.READ)
		if file == null or file.get_length() > MAX_BYTES:
			return _fail("Cannot capture plugin file: " + path)
		files[path] = file.get_buffer(file.get_length())
	return {"ok": true}


## A bundle contains source bytes. Only resource text is normalized; arbitrary
## binary assets retain their exact bytes. Paths are relative to this build.
func bundle(files: Dictionary) -> Dictionary:
	var normalized: Dictionary = {}
	var total := 0
	for key: Variant in files:
		if not key is String or not safe_relative(str(key)):
			return _fail("Invalid generation file path: " + str(key))
		var name: String = key
		if name.ends_with(".uid") or name.ends_with(".import"):
			continue
		if not files[key] is PackedByteArray:
			return _fail("Generation file is not bytes: " + name)
		var bytes: PackedByteArray = files[key]
		total += bytes.size()
		if total > MAX_BYTES:
			return _fail("Plugin generation exceeds 32 MiB")
		if name.get_extension() in ["gd", "tscn", "tres"]:
			var text_result := normalize_resource(name, bytes.get_string_from_utf8())
			if not text_result.get("ok", false):
				return text_result
			bytes = str(text_result.text).to_utf8_buffer()
		normalized[name] = bytes
	if normalized.is_empty():
		return _fail("Empty plugin generation")
	return {"ok": true, "digest": digest_files(normalized), "files": normalized}


static func safe_relative(path: String) -> bool:
	return not path.is_empty() and not path.is_absolute_path() \
		and not path.contains(":") and not path.contains("\\") \
		and path == path.simplify_path() and not path.begins_with(".") \
		and not path.contains("/.")


func normalize_resource(name: String, text: String) -> Dictionary:
	var uid := RegEx.new()
	uid.compile(' uid="uid://[^"\\n]+"')
	var cleaned := text
	if name.get_extension() in ["tscn", "tres"]:
		var lines := text.split("\n")
		for index: int in range(lines.size()):
			var line := lines[index].strip_edges()
			if line.begins_with("[ext_resource") and line.contains("uid=") and not line.contains("path="):
				return _fail("UID-only resource has no relative path: " + name)
			if line.begins_with("[gd_scene") or line.begins_with("[gd_resource") or line.begins_with("[ext_resource"):
				lines[index] = uid.sub(lines[index], "", true)
		cleaned = "\n".join(lines)
	# A deliberately strict outer rule also covers resource paths in reflective
	# calls or syntax this small lexer does not recognize. Comments count too:
	# opting in requires spelling only public host paths anywhere in source.
	var unmatched := cleaned
	for allowed: String in HOST_PATHS:
		unmatched = unmatched.replace(allowed, "")
	if unmatched.contains("res://") or unmatched.contains("user://") or unmatched.contains("uid://"):
		return _fail("Non-public resource path in opt-in source: " + name)
	for path: String in resource_references(cleaned, name.get_extension() == "gd"):
		if path.begins_with("res://"):
			if path not in HOST_PATHS:
				return _fail("Host resource is not a public live-reload API: " + path)
		elif path.begins_with("unsupported://") or path.begins_with("uid://") or path.is_absolute_path() or path.begins_with("../") or path.contains("/../"):
			return _fail("Non-local resource reference refused: " + path)
	return {"ok": true, "text": cleaned}


## Lex strings and comments before looking for resource calls. Unusual path
## literal forms are refused explicitly instead of partially interpreting them.
static func resource_references(text: String, is_script: bool) -> Array[String]:
	var lexer := RegEx.new()
	lexer.compile("#[^\\n]*|r?\\\"\\\"\\\"(?:\\\\.|\\\"(?!\\\"\\\")|[^\\\"\\\\])*\\\"\\\"\\\"|r?\\'\\'\\'(?:\\\\.|\\'(?!\\'\\')|[^\\'\\\\])*\\'\\'\\'|r?\\\"(?:\\\\.|[^\\\"\\\\])*\\\"|r?\\'(?:\\\\.|[^\\'\\\\])*\\'|[A-Za-z_][A-Za-z_0-9]*|[^\\s]")
	var tokens: Array[String] = []
	for token: RegExMatch in lexer.search_all(text):
		if not token.get_string().begins_with("#"):
			tokens.append(token.get_string())
	var result: Array[String] = []
	for index: int in range(tokens.size()):
		var token := tokens[index]
		if is_script and token in ["preload", "load"] and index + 2 < tokens.size() and tokens[index + 1] == "(":
			if index + 3 >= tokens.size() or tokens[index + 3] not in [")", ","]:
				result.append("unsupported://computed-resource-expression")
			else:
				result.append(_resource_literal(tokens[index + 2]))
		elif is_script and token == "extends" and index + 1 < tokens.size():
			var parent := tokens[index + 1]
			if parent.begins_with('"') or parent.begins_with("'") or parent.begins_with('r"') or parent.begins_with("r'"):
				result.append(_resource_literal(parent))
		elif not is_script and token == "path" and index + 2 < tokens.size() and tokens[index + 1] == "=":
			result.append(_resource_literal(tokens[index + 2]))
	return result


static func _resource_literal(token: String) -> String:
	# No guessed decoding: raw, multiline, escaped or computed resource paths
	# need a plain literal relative path before this plugin can opt in.
	if token.length() < 2 or token.begins_with("r") or token.contains("\\") or token.contains("\n"):
		return "unsupported://resource-expression"
	var quote := token.left(1)
	if quote not in ['"', "'"] or not token.ends_with(quote) or token.begins_with(quote.repeat(3)):
		return "unsupported://resource-expression"
	return token.substr(1, token.length() - 2)


static func digest_files(files: Dictionary) -> String:
	var paths: Array = files.keys()
	paths.sort()
	var hashes := ""
	for path: String in paths:
		var bytes: PackedByteArray = files[path]
		var context := HashingContext.new()
		context.start(HashingContext.HASH_SHA256)
		context.update(bytes)
		hashes += path + "\n" + context.finish().hex_encode() + "\n"
	return hashes.sha256_text()


static func valid_digest(value: String) -> bool:
	return value.length() == 64 and value.is_valid_hex_number(false)


func archive(build: Dictionary) -> Dictionary:
	if directory.is_empty() or not build.get("ok", false):
		return _fail("Invalid generation archive input")
	var digest: String = str(build.get("digest", ""))
	var files: Dictionary = build.get("files", {})
	if not valid_digest(digest) or digest_files(files) != digest:
		return _fail("Generation digest does not match source bytes")
	if not _ensure_directory():
		return _fail("Cannot create generation directory")
	var path := directory.path_join(digest + ".json")
	if FileAccess.file_exists(path):
		return read_archive(digest)
	var encoded: Dictionary = {}
	for name: String in files:
		var bytes: PackedByteArray = files[name]
		encoded[name] = bytes.hex_encode()
	if not Atomic.write(path, JSON.stringify({"version": 1, "files": encoded})):
		return _fail("Cannot write immutable generation archive")
	return read_archive(digest)


func read_archive(digest: String) -> Dictionary:
	if directory.is_empty() or not valid_digest(digest):
		return _fail("Invalid archive digest")
	var value := _read_json(directory.path_join(digest + ".json"))
	if value.get("version", 0) != 1 or not value.get("files") is Dictionary:
		return _fail("Missing or corrupt generation archive: " + digest)
	var files: Dictionary = {}
	var total := 0
	for key: Variant in value.files:
		if not key is String or not safe_relative(str(key)) or not value.files[key] is String:
			return _fail("Invalid archive file entry")
		var hex: String = value.files[key]
		if hex.length() % 2 != 0 or (not hex.is_empty() and not hex.is_valid_hex_number(false)):
			return _fail("Invalid archive byte encoding")
		var bytes := hex.hex_decode()
		total += bytes.size()
		if total > MAX_BYTES:
			return _fail("Archive exceeds 32 MiB")
		files[key] = bytes
	if files.is_empty() or digest_files(files) != digest:
		return _fail("Corrupt archive digest: " + digest)
	return {"ok": true, "digest": digest, "files": files}


func write_slot(slot: String, build: Dictionary) -> Dictionary:
	var target := slot_path(slot)
	if target.is_empty() or not build.get("ok", false):
		return _fail("Invalid slot or build")
	if not _ensure_directory():
		return _fail("Unsafe generation directory")
	var input_files: Dictionary = build.get("files", {})
	var checked := bundle(input_files)
	if not checked.get("ok", false) or checked.digest != build.get("digest", ""):
		return _fail("Slot source digest or resource validation failed")
	# A slot is rebuilt exactly, never overlaid on removed dependencies. Moving
	# an inactive directory preserves every byte until reviewed housekeeping
	# removes retired directories; this operation itself performs no deletes.
	if DirAccess.dir_exists_absolute(target):
		if _has_link(target):
			return _fail("Generation slot symlink refused")
		var retired := directory.path_join("retired-" + slot + "-" + str(Time.get_ticks_usec()))
		if DirAccess.rename_absolute(target, retired) != OK:
			return _fail("Cannot retire inactive slot before exact reconstruction")
	for name: String in build.files:
		var path := target.path_join(name)
		if _has_link(path):
			return _fail("Generation slot symlink refused")
		if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
			return _fail("Cannot create slot directory")
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			return _fail("Cannot write slot source: " + name)
		var bytes: PackedByteArray = build.files[name]
		var stored := file.store_buffer(bytes)
		file.flush()
		var success := stored and file.get_error() == OK
		file.close()
		if not success:
			return _fail("Cannot flush slot source: " + name)
	return {"ok": true, "directory": target}


## The recovery record always names the previously published build. A temp
## selector never confers publication authority after a process crash.
func prepare_selector(active: String, previous: Dictionary) -> Dictionary:
	if not valid_digest(active) or not read_archive(active).get("ok", false):
		return _fail("Cannot publish an invalid archive")
	var lkg := str(previous.get("active", ""))
	if not lkg.is_empty() and not valid_digest(lkg):
		return _fail("Invalid previous generation")
	var next := {"version": 1, "active": active, "lkg": lkg}
	if not previous.is_empty() and not Atomic.write(directory.path_join("recovery.json"), JSON.stringify(previous)):
		return _fail("Cannot prepare selector recovery record")
	if not Atomic.prepare(selector_path(), JSON.stringify(next)):
		return _fail("Cannot prepare generation selector")
	return {"ok": true, "record": next}


func publish_selector() -> Dictionary:
	if not Atomic.replace(selector_path() + ".tmp", selector_path()):
		return _fail("Cannot publish generation selector; previous build retained")
	return {"ok": true}


## validate receives an archived build and must actually compile/load/validate
## it before returning {ok:true}. Digest validity alone is not boot readiness.
func recover(validate: Callable) -> Dictionary:
	if not validate.is_valid() or directory.is_empty():
		return _fail("Boot validator required")
	var record := _read_json(selector_path())
	if not _valid_record(record):
		record = _read_json(directory.path_join("recovery.json"))
	if not _valid_record(record):
		return _fail("No published generation; initialize from installed sources")
	for key: String in ["active", "lkg"]:
		var digest := str(record.get(key, ""))
		if digest.is_empty():
			continue
		var build := read_archive(digest)
		if not build.get("ok", false):
			continue
		var validation: Variant = validate.call(build)
		if not validation is Dictionary:
			continue
		var checked_validation: Dictionary = validation
		if not checked_validation.get("ok", false):
			continue
		var chosen := record if key == "active" else {"version": 1, "active": digest, "lkg": ""}
		return {"ok": true, "build": build, "record": chosen, "recovered": key == "lkg", "digest": digest}
	return _fail("Active and last-known-good generations failed boot validation")


static func _valid_record(record: Dictionary) -> bool:
	return record.get("version", 0) == 1 and valid_digest(str(record.get("active", ""))) \
		and (str(record.get("lkg", "")).is_empty() or valid_digest(str(record.lkg)))


static func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_BYTES * 3:
		return {}
	var value: Variant = JSON.parse_string(file.get_as_text())
	return value if value is Dictionary else {}


func _ensure_directory() -> bool:
	return not directory.is_empty() and not _has_link(directory) \
		and DirAccess.make_dir_recursive_absolute(directory) == OK


static func _has_link(path: String) -> bool:
	if path != path.simplify_path():
		return true
	if _profile_path.is_empty():
		_profile_path = OS.get_user_data_dir().simplify_path().trim_suffix("/")
	if _profile_real_path.is_empty():
		_profile_real_path = _resolve_profile_root(_profile_path)
	if _profile_real_path.is_empty():
		return true
	var current := path
	# The OS-selected profile can live below system/home aliases. Only its
	# root is resolved: plugin-controlled suffixes must retain their links.
	if path == _profile_path or path.begins_with(_profile_path + "/"):
		current = _profile_real_path + path.substr(_profile_path.length())
	var boundary := _profile_real_path if current == _profile_real_path \
		or current.begins_with(_profile_real_path + "/") else ""
	while current != current.get_base_dir() and current != boundary:
		var parent := DirAccess.open(current.get_base_dir())
		if parent != null and parent.is_link(current.get_file()):
			return true
		current = current.get_base_dir()
	return false


## Resolve only the OS-owned root, never a plugin path. Bound link chains so
## a broken/cyclic profile refuses instead of silently gaining authority.
static func _resolve_profile_root(path: String) -> String:
	var resolved := path
	for _link: int in 40:
		var current := resolved
		var suffix := PackedStringArray()
		var followed := false
		while current != current.get_base_dir():
			var parent := DirAccess.open(current.get_base_dir())
			if parent != null and parent.is_link(current.get_file()):
				var target := parent.read_link(current.get_file())
				if target.is_empty():
					return ""
				resolved = target if target.is_absolute_path() else current.get_base_dir().path_join(target)
				resolved = resolved.path_join("/".join(suffix)).simplify_path().trim_suffix("/")
				followed = true
				break
			suffix.insert(0, current.get_file())
			current = current.get_base_dir()
		if not followed:
			return resolved
	return ""
