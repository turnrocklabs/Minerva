class_name ChatGPTo1
extends ChatGPT4o

func _init():
	super()

	model_name = "o1"
	short_name = "O1"
	token_cost = 0.0150 / 1000 * 100

class Mini extends ChatGPTo1:
	func _init():
		super()

		model_name = "o1-mini"
		short_name = "OM"
		token_cost = 0.0030 / 1000 * 100

class Preview extends ChatGPTo1:
	func _init():
		super()

		model_name = "o1-preview"
		short_name = "OM"
		token_cost = 0.0150 / 1000 * 100
