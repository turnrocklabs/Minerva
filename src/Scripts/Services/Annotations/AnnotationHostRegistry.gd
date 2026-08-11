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
## No-op if either argument is empty/null. Re-registering the SAME host object
## (or the first registration for a name) always applies immediately.
##
## Collision policy (bug 019f6b9221b6 / host-resolution ambiguity): when a
## DIFFERENT host is already registered under `editor_name` — e.g. a generic
## buffer-canonical text host and a plugin panel host both binding to the same
## tab title — panel-host-priority wins: whichever host declares a non-"text"
## get_document_identity().kind is treated as the primary authoring surface and
## is kept/adopted regardless of arrival order. A generic text-buffer host is
## never allowed to displace an already-registered panel host, and a later
## panel host always displaces an already-registered text host. This mirrors
## the read path, where each editor keeps its OWN annotation_host reference
## and the file-backed plugin panel is what the user actually sees and edits —
## the shared registry (the only thing MCP tools consult) must resolve the
## same way. Collisions between two hosts of equal tier (including repeated
## registration of the identical host) keep the prior last-wins behavior.
static func register(editor_name: String, host: AnnotationHost) -> void:
	if editor_name.is_empty() or host == null:
		return
	var existing: AnnotationHost = _hosts.get(editor_name, null)
	if existing == null or existing == host:
		_hosts[editor_name] = host
		return

	var existing_kind := _document_kind(existing)
	var incoming_kind := _document_kind(host)
	if existing_kind == _TEXT_DOCUMENT_KIND and incoming_kind != _TEXT_DOCUMENT_KIND:
		# Panel host arriving after a generic text host: panel wins.
		_hosts[editor_name] = host
		return
	if existing_kind != _TEXT_DOCUMENT_KIND and incoming_kind == _TEXT_DOCUMENT_KIND:
		# Generic text host arriving after a panel host is already authoritative:
		# refuse to displace it so MCP tools keep resolving the panel surface.
		push_warning(
			("[AnnotationHostRegistry] register('%s'): refusing to replace the " +
			"registered panel host (kind='%s') with a generic text-buffer host. " +
			"The panel host stays authoritative for this editor name.")
			% [editor_name, existing_kind]
		)
		return
	# Equal tier (both text, both panel/unknown, etc.) — preserve prior semantics.
	_hosts[editor_name] = host


## Document-identity "kind" treated as the generic, lowest-priority tier.
## TextEditorAnnotationHost.get_document_identity() returns this; every other
## host (including the base AnnotationHost's "unknown" default and any plugin
## panel host's own kind) is treated as a more-specific authoring surface.
const _TEXT_DOCUMENT_KIND := "text"


## Best-effort read of a host's declared document kind. Never throws — hosts
## that don't override get_document_identity() (or fail to return a Dictionary)
## are treated as "unknown", which is NOT the text tier and so is never
## deprioritized below an actual text-buffer host.
static func _document_kind(host: AnnotationHost) -> String:
	if host == null or not host.has_method("get_document_identity"):
		return "unknown"
	var identity: Variant = host.get_document_identity()
	if identity is Dictionary:
		return str((identity as Dictionary).get("kind", "unknown"))
	return "unknown"


## Remove the registration for `editor_name`. No-op if not registered.
## Panels MUST call this on _exit_tree so a stale RefCounted host doesn't
## linger in the registry preventing free.
##
## `expected_host`, if given, makes the erase identity-checked: the entry is
## only removed when it currently holds THIS host. This guards against a
## lower-priority host (e.g. a text buffer that lost a registration collision
## to a panel host, per register()'s policy above) wiping out the panel host's
## live entry when its own editor tab closes. Defaults to null to preserve the
## existing unconditional-erase behavior for callers that don't pass a host
## (current Editor.gd call sites) — see 019f6b9221b6 follow-up.
static func deregister(editor_name: String, expected_host: AnnotationHost = null) -> void:
	if expected_host != null and _hosts.get(editor_name, null) != expected_host:
		return
	_hosts.erase(editor_name)


## Return the registered host for `editor_name`, or null if none.
##
## Broker fallback (LLM ergonomics, docket 019fcb06ca0b): a plugin scene panel
## registers here at mount under ctx.editor.tab_title — which is captured
## BEFORE an MCP-created tab's custom title is applied, so this registry can
## hold a stale default name ("pcb · pcb_panel") while every OTHER tool family
## resolves the live tab title through the scene-panel broker. When the direct
## lookup misses, resolve the panel by that same broker path (duck-typed and
## lazy — no parse dependency on the plugin layer) and ask it for its
## annotation host, so one editor_name works across all tool families. Names
## that hit the registry directly behave exactly as before.
static func get_host(editor_name: String) -> AnnotationHost:
	var direct: AnnotationHost = _hosts.get(editor_name, null)
	if direct != null:
		return direct
	var panel: Object = _broker_panel(editor_name)
	if panel != null and panel.has_method("get_annotation_host"):
		var host: Variant = panel.get_annotation_host()
		if host is AnnotationHost:
			return host
	return null


## Resolve a live scene panel by editor tab name through SingletonObject's
## plugin_scene_panel_broker — the identical duck-typed lookup
## PluginToolRegistry uses to dispatch panel tools, so the two tool families
## cannot resolve the same name differently. Null when the broker (or the
## whole scene tree) is absent, e.g. in headless unit tests.
static func _broker_panel(editor_name: String) -> Object:
	if editor_name.is_empty():
		return null
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return null
	var root: Node = (loop as SceneTree).root
	if root == null:
		return null
	var so: Node = root.get_node_or_null("SingletonObject")
	if so == null or not ("plugin_scene_panel_broker" in so):
		return null
	var broker: Variant = so.get("plugin_scene_panel_broker")
	if broker == null or not (broker as Object).has_method("get_panel_for_editor"):
		return null
	var panel: Variant = broker.get_panel_for_editor(editor_name)
	if panel is Object and is_instance_valid(panel):
		return panel
	return null


## Return the list of currently-registered editor names.
## Useful for diagnostics and the MCP-tool error path that wants to
## suggest valid editor names when the caller's argument doesn't match.
## Broker panel names are appended (deduplicated) so the "Known:" hint in
## MCP errors lists every name get_host() can actually resolve.
static func list_editor_names() -> Array:
	var names: Array = _hosts.keys()
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var root: Node = (loop as SceneTree).root
		var so: Node = root.get_node_or_null("SingletonObject") if root != null else null
		if so != null and "plugin_scene_panel_broker" in so:
			var broker: Variant = so.get("plugin_scene_panel_broker")
			if broker != null and (broker as Object).has_method("list_panel_editor_names"):
				for n in broker.list_panel_editor_names():
					if not names.has(n):
						names.append(n)
	return names


## Test-only: drop all registrations. Production code never needs this.
static func _reset_for_test() -> void:
	_hosts.clear()
