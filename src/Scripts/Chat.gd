extends Control

@onready var prompt_count_label: Label = %PromptCountLabel

var initial_label_text: String
func _ready() -> void:
	initial_label_text = prompt_count_label.text


func _process(_delta: float) -> void:
	# this is for changing the minimum size of the panel and 
	# changing the text when is being resized
	if size.x < 540:
		prompt_count_label.text = "Estimated tokens:"
		custom_minimum_size.x = 480
	if size.x >= 540:
		prompt_count_label.text = initial_label_text
		custom_minimum_size.x = 500
