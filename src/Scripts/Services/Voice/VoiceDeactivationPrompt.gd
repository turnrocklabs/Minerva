class_name VoiceDeactivationPrompt
extends Node
## Resolves from dialog decisions rather than visibility ordering.

signal decided(accepted: bool)
var dialog: ConfirmationDialog


func ask(parent: Node) -> bool:
	dialog = ConfirmationDialog.new()
	dialog.title = "Disable Voice Support?"
	dialog.dialog_text = "This stops active TurnRock transcription and speech. OpenAI transcription and chat remain available."
	parent.add_child(dialog)
	dialog.confirmed.connect(func(): decided.emit(true), CONNECT_ONE_SHOT)
	dialog.canceled.connect(func(): decided.emit(false), CONNECT_ONE_SHOT)
	dialog.popup_centered()
	var accepted: bool = await decided
	dialog.queue_free()
	return accepted
