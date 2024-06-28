class_name ChatGPT35Turbo
extends ChatGPTBase


func _init():
	super()
	
	model_name = "gpt-3.5-turbo"
	short_name = "O3.5"
	token_cost = 0.5 / 1000000.0 # https://openai.com/api/pricing/
