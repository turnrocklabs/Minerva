class_name ChatGPT4o
extends ChatGPTBase

func _init():
	super()

	model_name = "gpt-4o"
	short_name = "O4"
	token_cost = 5.0 / 1000000.0 # https://openai.com/api/pricing/
