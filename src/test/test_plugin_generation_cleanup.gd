extends SceneTree
## Execute only after independent review of the generation deletion boundary.
const Store := preload("res://Scripts/Services/Plugins/PluginGenerationStore.gd")
const Cleanup := preload("res://Scripts/Services/Plugins/PluginGenerationCleanup.gd")
const Atomic := preload("res://Scripts/Services/Plugins/AtomicFile.gd")
var checks: int = 0
var failed: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var store := Store.new("cleanup_contract")
	var builds: Array[Dictionary] = []
	for value: int in 4:
		var build := store.bundle({"payload.txt": str(value).to_utf8_buffer()})
		check(store.archive(build).get("ok", false), "immutable fixture archive")
		builds.append(build)
	var first := store.prepare_selector(str(builds[0].digest), {})
	check(first.get("ok", false) and store.publish_selector().get("ok", false), "publish initial build")
	var current := store.prepare_selector(str(builds[1].digest), first.record)
	check(current.get("ok", false) and store.publish_selector().get("ok", false), "publish current with LKG")
	var selector := FileAccess.get_file_as_bytes(store.selector_path())
	var protected_path := "user://plugins/cleanup-user-data.txt"
	check(Atomic.write(protected_path, "newer user data"), "write independent user data")
	check(Atomic.write(store.directory.path_join("notes.json"), "preserve unknown files"), "write nonarchive metadata")
	var retired := store.directory.path_join("retired-A-123/nested/.hidden")
	DirAccess.make_dir_recursive_absolute(retired.get_base_dir())
	check(Atomic.write(retired, "obsolete cache"), "write obsolete hidden cache")
	var reply := Cleanup.collect(store, current.record, str(builds[2].digest))
	check(reply.get("ok", false) and reply.removed == 2, "delete only obsolete archive and retired cache")
	check(not DirAccess.dir_exists_absolute(store.directory.path_join("retired-A-123"))
		and not FileAccess.file_exists(store.directory.path_join(str(builds[3].digest) + ".json")), "obsolete files are gone")
	for index: int in 3:
		check(store.read_archive(str(builds[index].digest)).get("ok", false), "retain active, LKG and pending-installed build")
	check(FileAccess.get_file_as_bytes(store.selector_path()) == selector
		and FileAccess.get_file_as_string(protected_path) == "newer user data"
		and FileAccess.file_exists(store.directory.path_join("notes.json")), "selectors, user data and unknown files untouched")
	check(Cleanup.collect(store, current.record).get("ok", false), "second collection converges")
	check(Cleanup.collect(store, current.record).removed == 0, "repeated collection removes nothing")
	# A cache link must fail the whole deletion plan, preserving both its target
	# and a separate obsolete archive. No deletion runs before the plan is safe.
	var extra := store.bundle({"extra.txt": "obsolete".to_utf8_buffer()})
	check(store.archive(extra).get("ok", false), "extra obsolete archive")
	var linked_dir := store.directory.path_join("retired-B-456")
	DirAccess.make_dir_recursive_absolute(linked_dir)
	var link_dir := DirAccess.open(linked_dir)
	var link_error := link_dir.create_link(ProjectSettings.globalize_path(protected_path), linked_dir.path_join("escape"))
	if OS.get_name() == "Linux":
		check(link_error == OK, "create real cache symlink")
		var refused := Cleanup.collect(store, current.record)
		check(not refused.get("ok", true) and str(refused.error).contains("symlink"), "symlink refuses entire deletion plan")
		check(FileAccess.get_file_as_string(protected_path) == "newer user data"
			and store.read_archive(str(extra.digest)).get("ok", false), "refusal preserves target and unexecuted obsolete archive")
	else:
		print("SKIP: Linux symlink fixture; Windows/macOS release checks remain B6 obligations")
	print("Generation cleanup: %d checks, %d failures" % [checks, failed])
	quit(1 if failed else 0)


func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failed += 1
	print(("PASS: " if condition else "FAIL: ") + label)
