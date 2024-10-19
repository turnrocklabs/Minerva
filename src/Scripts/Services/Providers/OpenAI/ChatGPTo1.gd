class_name ChatGPTo1
extends ChatGPT4o

func _init():
	super()

	model_name = "o1-preview"
	short_name = "O1"
	token_cost = 15.00 / 1000000.0 # https://openai.com/api/pricing/
