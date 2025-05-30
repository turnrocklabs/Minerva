class_name ChatGPTo3
extends ChatGPT4o

class o3 extends ChatGPTo3:
	func _init():
		super()

		model_name = "o3"
		display_name = "03"
		short_name = "O3"
		token_cost = 1.1 / 1_000_000 * 100
	
	func generate_content(prompt: Array[Variant], additional_params: Dictionary={}) -> BotResponse:
		
		additional_params.merge({
			"reasoning_effort": "medium"
		}, true)

		return await super(prompt, additional_params)

class MiniMedium extends ChatGPTo3:
	func _init():
		super()

		model_name = "o4-mini"
		display_name = "04-mini-medium"
		short_name = "OM"
		token_cost = 1.1 / 1_000_000 * 100
	
	func generate_content(prompt: Array[Variant], additional_params: Dictionary={}) -> BotResponse:
		
		additional_params.merge({
			"reasoning_effort": "medium"
		}, true)

		return await super(prompt, additional_params)


class MiniHigh extends ChatGPTo3:
	func _init():
		super()

		model_name = "o4-mini"
		display_name = "04-mini-high"
		short_name = "OH"
		token_cost = 1.1 / 1_000_000 * 100
	

	func generate_content(prompt: Array[Variant], additional_params: Dictionary={}) -> BotResponse:
		
		additional_params.merge({
			"reasoning_effort": "high"
		}, true)

		return await super(prompt, additional_params)
