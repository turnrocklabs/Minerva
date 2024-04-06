# Godot 4 changes
I'm using GoDot 4, specifically 4.2. It has new syntax / changes over previous versions of Godot. Here's a quick list:

## Conceptual changes

### Scene unique variables.
The previous "$" syntax to refer to objects in the heirarchy has been deprecated, and pleaced by scene uniqe variables.  "$" control syntax is no invalid.

Variables can be set unique in a scene to refer to Godot controls. This is done by using the % sign.  So, if I make a any control in the editor and set the unique name property, I can then access that node by prefixing % to the name in GDScript.  Example:
- set it: a VBoxControl unique name to %fubar in the editor.
- use it: %fubar.add_child(checkbox)

### Signal connection API change.
The connect API has changed.  Previously, the 3 argument API was object.connect(signal_name, object, handler_name) where both signal_name and handler_name were strings representing the signal to subscribe to and the handler, respectively.  Now, the API has 2 arguments, the signal_name, and the function in the object instance to call.  Example:
old: http_request.connect("request_completed", self, "_on_request_completed")
new: http_request.connect("request_completed", self._on_request_completed)


# API Changes
- The Reference base class is deprecated.  Use RefCounted instead.
- parse_json is deprecated.  Use the JSON class instead.  You must instance the class and use instance.parse_string now.
Example:
var my_json = JSON.new()
var foo = my_json.parse_string{json_string)
- PopupDialog is deprecated.  Use PopupPanel instead.

