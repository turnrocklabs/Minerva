class_name MinervaPluginPanel
extends Control
## Optional base class for plugin panels (godot_scene kind).
##
## Plugins MAY extend this class on their panel root script to surface every
## platform hook in the IDE — Godot's autocomplete will list each virtual
## method, and inline doc comments document each contract.  Panels MAY also
## extend Control directly; the platform's hook dispatch is duck-typed and
## both paths work.  Subclassing this is recommended but not required.
##
## Hook contracts:
##   _on_panel_loaded(ctx)         — fires once after the scene is mounted and
##                                   the broker is wired.  ctx contains:
##                                   plugin_id, panel_name, data_directory,
##                                   broker, file_path, associated_object,
##                                   editor, host_api_version.
##   _on_panel_unload()            — fires once before the scene is freed.
##                                   Disconnect signals here.  Do NOT initiate
##                                   IPC inside this hook — the broker rejects
##                                   late requests with panel_unloading.
##   _on_panel_save_request()      — return a Dictionary describing the panel's
##                                   complete save state.  Used for both
##                                   host_owned file save (Ctrl+S writes the
##                                   returned Dict to disk as JSON) and
##                                   project-state capture (returned Dict is
##                                   stashed in the .minproj entry).  Capture
##                                   EVERY visible bit the user might expect
##                                   to come back: input contents, derived
##                                   labels, dirty flag, scroll, selection.
##   _on_panel_load_request(doc)   — restore state previously returned by
##                                   _on_panel_save_request.  Called for both
##                                   host_owned file open and project-state
##                                   restore.
##   _on_panel_undo_request()      — revert one step of the panel's own
##   _on_panel_redo_request()        history; return true when a step was
##                                   applied.  Declare BOTH or NEITHER: the
##                                   editor ribbon shows its Undo/Redo buttons
##                                   only when both exist, and hides them
##                                   otherwise.  Not defined on this base class
##                                   on purpose — a default would make every
##                                   panel look undo-capable.
##   receive(channel, payload)     — broker-side push from the plugin server.
##                                   Override to handle named messages.
##   on_progress(rid, phase, frac) — receive progress events for in-flight
##                                   plugin requests routed to this panel.
##
## See: Docs/design/Plugin-platform-design.md §5 for the full lifecycle.
## See: src/plugins/hello_scene/ for a working reference plugin.


# ---------------------------------------------------------------------------
# Scene-contract signals (design §4.2)
# ---------------------------------------------------------------------------

## Emitted by the panel to call a plugin IPC channel through the broker.
## reply_id is a unique-per-panel string; the broker routes the result back via
## $_MinervaIPC._reply(reply_id, result).  Use $_MinervaIPC.await_reply(reply_id)
## in your handler to coroutine-await the result.
## Subclass plugin panels emit this; the parser can't see usage from this base file.
@warning_ignore("unused_signal")
signal request(channel: String, payload: Dictionary, reply_id: String)

## Emitted whenever the document the panel represents has changed.  The
## platform listens to this to flip the Editor's is_modified flag and surface
## the unsaved-changes indicator on the tab.
@warning_ignore("unused_signal")
signal content_changed()


# ---------------------------------------------------------------------------
# Lifecycle hooks — override what your plugin needs.
# ---------------------------------------------------------------------------

## Called once after the scene is mounted and the broker has been wired.
## Override to capture ctx, set up your initial UI, kick off any deferred work.
func _on_panel_loaded(_ctx: Dictionary) -> void:
	pass


## Called once before the scene is removed from the tree and freed.
## Override to disconnect signals.  Do NOT start new IPC requests here.
func _on_panel_unload() -> void:
	pass


## Return a Dictionary representing the panel's complete save state.
## Default: empty Dict.  Override to capture every visible/editable bit.
##
## The returned shape is opaque to the platform — your plugin defines it.
## Whatever you return here is what your _on_panel_load_request(doc) sees on
## restore.  Plan the schema for forward-compatibility (include a `version`
## key if you anticipate evolving it).
func _on_panel_save_request() -> Dictionary:
	return {}


## Restore state previously captured by _on_panel_save_request.
## Default: no-op.  Override to apply the document into your widgets.
func _on_panel_load_request(_document: Dictionary) -> void:
	pass


## Receive an asynchronous push from the plugin server.
## Default: warn-and-drop.  Override and switch on `channel` to handle each
## message type your plugin pushes.
func receive(channel: String, _payload: Dictionary) -> void:
	push_warning("[%s] receive: unhandled channel '%s'" % [name, channel])


## Receive a progress event for an in-flight request.
## Default: no-op.  Override to update progress UI.
##
## phase: implementation-defined string (e.g. "loading", "rendering").
## fraction: 0.0..1.0.
func on_progress(_request_id: String, _phase: String, _fraction: float) -> void:
	pass


## Optional annotation substrate hook. Annotation-capable plugin panels override
## this and return their live AnnotationHost. The editor pane uses it to mount
## Minerva's shared dock/workbench around the plugin surface.
func get_annotation_host() -> RefCounted:
	return null
