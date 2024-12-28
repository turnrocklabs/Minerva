class_name ChatGPTo1
extends ChatGPT4o

func _init():
	super()

	model_name = "o1-mini"
	short_name = "O1"
	token_cost = 0.000015 # https://openai.com/api/pricing/
