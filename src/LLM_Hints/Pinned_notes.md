# Godot 4 changes
I'm using GoDot 4, specifically 4.2. It has new syntax / changes over previous versions of Godot. Here's a quick list:

## Conceptual changes

### Scene unique variables.
The previous "$" syntax to refer to objects in the heirarchy has been deprecated, and replaced by scene uniqe variables.  "$" control syntax is no longer valid, and any $ references in code will now break.

Variables can be set unique in a scene to refer to Godot controls. This is done by using the % sign.  So, if I make a any control in the editor and set the unique name property, I can then access that node by prefixing % to the name in GDScript.  
Example:
- set it: a VBoxControl unique name to %fubar in the editor.
- use it: %fubar.add_child(checkbox)

### Signal connection API change.
The connect API has changed.  Previously, the 3 argument API was object.connect(signal_name, object, handler_name) where both signal_name and handler_name were strings representing the signal to subscribe to and the handler, respectively.  Now, the API has 2 arguments, the signal_name, and the function in the object instance to call.  Example:
old: http_request.connect("request_completed", self, "_on_request_completed")
new: http_request.connect("request_completed", self._on_request_completed)

Signals can now also be set by "." notation.  Another way to connect the http_request's request_completed signal would look like this:
http_request.request_completed.connect(self._on_request_completed)

# Godot 4.2 Library/API Changes
- The Reference base class is deprecated.  Use RefCounted instead.
- PopupDialog is deprecated.  Use PopupPanel instead.
- parse_json is deprecated.  Use the JSON class instead.  You must instance the class and use instance.

## JSON Parsing ##
Previously, we would use JSON.parse_string().  In 4.2, this is no longer supported. Instead, instance the JSON class and use parse_string from there.
Example:
var my_json = JSON.new()
var foo = my_json.parse_string{json_string)

