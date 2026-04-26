class_name AnnotationHostRegistry
extends RefCounted
## Process-global registry of live AnnotationHosts keyed by editor tab name.
##
## Why this exists: MCP tools that query annotations (minerva_annotations_list)
## otherwise read only from the on-disk sidecar — meaning newly-drawn
## annotations are invisible to the LLM until the user explicitly saves the
## project. That breaks the "ask Claude what I just drew" flow because the
## user doesn't think "I need to save first".
##
## Lookup key: the editor tab title — the same identifier surfaced by
## minerva_list_editors. Plugin panels register on _ready (after building
## their AnnotationHost) and deregister on _exit_tree. Re-registering the
## same editor name overwrites the previous entry.
##
## Implementation: a static Dictionary on the class. GDScript class-level
## statics live for the lifetime of the process, which is exactly the
## scope we need. No autoload required.
##
## Concurrency: GDScript is single-threaded for script execution, so plain
## Dictionary mutation is safe here. If a future caller wants to enumerate
## from a thread, copy via list_editor_names() into a local first.

static var _hosts: Dictionary = {}  # editor_name (String) → AnnotationHost


## Register a live host under the given editor name.
## No-op if either argument is empty/null. Idempotent: re-registering with
## the same name overwrites the previous host (typical when a panel is closed
## and reopened by the user).
static func register(editor_name: String, host: AnnotationHost) -> void:
	if editor_name.is_empty() or host == null:
		return
	_hosts[editor_name] = host


## Remove the registration for `editor_name`. No-op if not registered.
## Panels MUST call this on _exit_tree so a stale RefCounted host doesn't
## linger in the registry preventing free.
static func deregister(editor_name: String) -> void:
	_hosts.erase(editor_name)


## Return the registered host for `editor_name`, or null if none.
static func get_host(editor_name: String) -> AnnotationHost:
	return _hosts.get(editor_name, null)


## Return the list of currently-registered editor names.
## Useful for diagnostics and the MCP-tool error path that wants to
## suggest valid editor names when the caller's argument doesn't match.
static func list_editor_names() -> Array:
	return _hosts.keys()


## Test-only: drop all registrations. Production code never needs this.
static func _reset_for_test() -> void:
	_hosts.clear()
