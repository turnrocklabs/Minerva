class_name PendingMessageBubble
extends PanelContainer
## Placeholder bubble for a message the user submitted while the chat was busy.
## It shows the queued text in the chat immediately, so nothing the user typed
## disappears while an earlier turn is still running, and it carries a remove
## button that drops the entry from ChatOutgoingQueue before it ever runs.
## The bubble is view-only: the queue is the record, this node is its display.

signal removal_requested(bubble: PendingMessageBubble)

@onready var _text_label: Label = %PendingText
@onready var _remove_button: Button = %RemovePending

## Cached so callers can set the text before the node enters the tree.
var _message: String = ""


func _ready() -> void:
	_text_label.text = _message
	_remove_button.pressed.connect(_on_remove_pressed)


## Queued message text shown in the bubble.
func set_message(text: String) -> void:
	_message = text
	if is_node_ready():
		_text_label.text = text


func get_message() -> String:
	return _message


func _on_remove_pressed() -> void:
	removal_requested.emit(self)
