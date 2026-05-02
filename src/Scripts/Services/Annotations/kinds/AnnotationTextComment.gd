class_name AnnotationTextComment
extends AnnotationKind
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


func body_view_factory(annotation: Dictionary, _emit_patch: Callable) -> Control:
	var payload: Dictionary = annotation.get("kind_payload", {})
	var comment_text := str(payload.get("text", ""))

	var vbox := VBoxContainer.new()

	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.text = comment_text
	vbox.add_child(body)

	var footer := HBoxContainer.new()
	var author_kind := str(annotation.get("author", {}).get("kind", ""))
	var author_label := Label.new()
	author_label.text = author_kind if not author_kind.is_empty() else "unknown"
	author_label.modulate = Color(0.6, 0.6, 0.6, 1.0)
	footer.add_child(author_label)

	var lifecycle := str(annotation.get("lifecycle", "open"))
	var lifecycle_label := Label.new()
	lifecycle_label.text = lifecycle
	lifecycle_label.modulate = Color(0.6, 0.6, 0.6, 1.0)
	footer.add_child(lifecycle_label)
	vbox.add_child(footer)

	var reply_btn := Button.new()
	reply_btn.text = "Reply…"
	reply_btn.disabled = true
	reply_btn.tooltip_text = "Replies coming soon"
	# Reply behavior tracked in docket task 019de68e4667.
	vbox.add_child(reply_btn)

	return vbox
