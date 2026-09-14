class_name AnnotationTextComment
extends AnnotationKind
const _ThreadScript = preload("res://Scripts/Services/Annotations/AnnotationCommentThread.gd")
const _ThreadViewScene = preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationCommentThreadView.tscn")
## Built-in annotation kind: text_comment.
##
## Represents an inline code/text comment anchored to a core/text.range.
## The host (TextEditorAnnotationCanvas) owns all visual rendering —
## underline, gutter badge, and selection halo — so has_visual_render()
## returns false to opt out of the platform overlay render path.


func _init() -> void:
	name = &"text_comment"
	display_name = "Comment"
	owning_plugin = &"core"
	primitives_optional = true
	schema_version = 2


func has_visual_render() -> bool:
	return false


func accepted_anchor_types() -> Array:
	return ["core/text.range"]


## Empty rect: host-owned canvas means no 2D overlay bounds.
## has_visual_render() is false so the platform overlay never calls this,
## but the abstract contract requires an override.
func bounds(_annotation: Dictionary) -> Rect2:
	return Rect2()


func summary(annotation: Dictionary) -> String:
	var payload: Dictionary = annotation.get("kind_payload", {})
	var text := str(payload.get("text", "")).strip_edges()
	if text.is_empty():
		return display_name
	if text.length() > 80:
		text = text.substr(0, 77) + "..."
	return "%s: %s" % [display_name, text]


## The comment body IS this kind's free text (see AnnotationKind.text_content).
func text_content(annotation: Dictionary) -> String:
	return _ThreadScript.export_text(annotation)


func to_chat_context(annotation: Dictionary, capabilities: Dictionary) -> Array:
	var blocks := super(annotation, capabilities)
	var thread_text := text_content(annotation)
	if thread_text.length() > 2000:
		thread_text = thread_text.substr(0, 1997) + "..."
	for block in blocks:
		if block is Dictionary and str((block as Dictionary).get("type_name", "")) == "TEXT":
			var stale := str(annotation.get("lifecycle", "")) == "stale" or bool(annotation.get("stale", false))
			(block as Dictionary)["content"] = "[BROKEN] %s" % thread_text if stale else thread_text
	return blocks


func body_view_factory(annotation: Dictionary, emit_patch: Callable) -> Control:
	var view: Control = _ThreadViewScene.instantiate()
	view.call("setup", annotation, emit_patch)
	return view
