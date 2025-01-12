class_name IconsButton
extends Button

@export var icon_24: Texture
@export var icon_48: Texture
@export var icon_68: Texture


func _ready() -> void:
	SingletonObject.set_icon_size_24.connect(set_24_icon)
	SingletonObject.set_icon_size_48.connect(set_48_icon)
	SingletonObject.set_icon_size_68.connect(set_68_icon)


func set_24_icon() -> void:
	if icon_24:
		self.icon = icon_24


func set_48_icon() -> void:
	if icon_48:
		self.icon = icon_48


func set_68_icon() -> void:
	if icon_68:
		self.icon = icon_68
