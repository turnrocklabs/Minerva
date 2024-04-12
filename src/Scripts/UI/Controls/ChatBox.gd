## ChatBox is used for displaying messages to/from the user and any other chattable control.
class_name ChatBox
extends Control

enum CHATTYPE {USER, BOT, AVATAR} ## avatar is a remote human
signal memorizetext(text: String)
signal copytext(text:String)
signal text_extracted(text:Array[String])



## Properties we want to expose as API properties for the chattable interface
var text: String: set =  settext, get = gettext
var font_size: float

var _margin: int = 25
var _font_size: float
var _type: CHATTYPE
var _margin_container: MarginContainer
var _editabletext_control: RichTextLabel

## Layout controls
var _parent: Control
var _size: Vector2i
var _chars_per_line: int # Used to figure out how tall to make the control based on the number of lines
var _number_lines: float # holds how many total lines there are to display the text.
var _vertical_ppi: float # uses the size of the control and the font size for figuring out how many lines needed for word wrap

func _init(parent:Control, type:CHATTYPE):
	# setup some private variables
	self.font_size = 12.0
	self._vertical_ppi = self.font_size * 3
	self._parent = parent
	self._type = type
	self.name = "ChatBoxControl"

	# setup a margin container and configure it, but not add it to the scene tree yet.
	var the_margins: MarginContainer = MarginContainer.new()
	the_margins.name = "MarginContainer"
	if type == CHATTYPE.BOT:
		the_margins.add_theme_constant_override("margin_left", 10)
	else:
		the_margins.add_theme_constant_override("margin_right", 10)
	self._margin_container = the_margins

	# setup a rich text label, but again, don't add to scene tree yet.
	var the_text: RichTextLabel = RichTextLabel.new()
	the_text.name = "LabelControl"
	the_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	the_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	the_text.push_font_size(self.font_size)
	self._editabletext_control = the_text
	pass

func _ready():
	# we need a hierarchy of controls -- a MarginContainer, and a richtextlabel, maybe
	self.size = self._parent.size
	self._margin_container.add_child(self._editabletext_control)
	add_child(self._margin_container)
	pass

# figures out the size of the parent, subtracts a margin, 
func _calculate_line_length() -> float:
	## Figure out how wide the display area is and the font size.
	var size: Vector2 = self._parent.size
	var available_width = size.x - self._margin
	var line_length: float = available_width / self.font_size
	return(line_length)

func settext(_text:String):
	text = _text
	var line_count = 1

	# calculate the lines by counting any new line or similar characters
	line_count += text.count("\n")
	line_count += text.count("\r")
	
	## figure out how many X chars we can do for word wrap.
	var line_length:float = _calculate_line_length()
	if self._editabletext_control != null:
		line_count += (len(self.text) * _font_size) / line_length
		self._size = self._parent.size
		var target_size = self._size
		target_size.y = self._vertical_ppi * line_count
		_editabletext_control.text = self.text
		_editabletext_control.size = target_size
	pass

func gettext() -> String:
	return(text)
