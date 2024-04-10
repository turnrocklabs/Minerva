extends HBoxContainer


# Called when the node enters the scene tree for the first time.
func _ready():
	# Configure the error window size and give the panel to a singleton to use
	var target_size = self.size / 2
	%ErrorDisplayPopup.borderless = false
	%ErrorDisplayPopup.size = target_size
	SingletonObject.errorPopup = %ErrorDisplayPopup
	SingletonObject.errorTitle = %lblErrorHeader
	SingletonObject.errorText = %lblErrorMessage
	
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
#func _process(delta):
#	pass
