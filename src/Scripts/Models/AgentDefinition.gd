class_name AgentDefinition
extends RefCounted
## Typed model for agent definitions, replacing untyped Dictionaries.
## Follows the MemoryThread pattern (RefCounted + Serialize/Deserialize).
##
## Core fields (sent to backend via Serialize()):
##   agent_id, name, prompt, model, tools_enabled, setup_commands
##
## Swarm fields (client-side only, not sent to Core):
##   address, docket, notes_thread, skills_thread, parent, role,
##   autonomy, requires_supervisor, requires_human, codetools_deny

signal changed(property: StringName)

## Fields that Core backend knows about.
static var CORE_FIELDS := ["agent_id", "name", "prompt", "model", "tools_enabled", "setup_commands"]

## All serializable fields (Core + swarm).
static var SERIALIZER_FIELDS := [
	"agent_id", "name", "prompt", "model", "tools_enabled", "setup_commands",
	"address", "docket", "notes_thread", "skills_thread", "parent", "role",
	"autonomy", "requires_supervisor", "requires_human", "codetools_deny",
]


# -- Core fields (backend-known) ----------------------------------------------

var agent_id: String = "":
	set(value):
		agent_id = value
		_property_updated(&"agent_id")

var name: String = "":
	set(value):
		name = value
		_property_updated(&"name")

var prompt: String = "":
	set(value):
		prompt = value
		_property_updated(&"prompt")

var model: String = "":
	set(value):
		model = value
		_property_updated(&"model")

var tools_enabled: bool = false:
	set(value):
		tools_enabled = value
		_property_updated(&"tools_enabled")

var setup_commands: Array[String] = []:
	set(value):
		setup_commands = value
		_property_updated(&"setup_commands")


# -- Swarm fields (client-side only) ------------------------------------------

## Short addressable name for voice/chat reference.
var address: String = "":
	set(value):
		address = value
		_property_updated(&"address")

## Path to this agent's .dct file.
var docket: String = "":
	set(value):
		docket = value
		_property_updated(&"docket")

## Tab name holding research findings.
var notes_thread: String = "":
	set(value):
		notes_thread = value
		_property_updated(&"notes_thread")

## Tab name holding skill notes.
var skills_thread: String = "":
	set(value):
		skills_thread = value
		_property_updated(&"skills_thread")

## Supervisor agent_id that owns this agent (tree structure).
var parent: String = "":
	set(value):
		parent = value
		_property_updated(&"parent")

## "agent" or "supervisor".
var role: String = "agent":
	set(value):
		role = value
		_property_updated(&"role")

## Actions the agent can perform freely.
var autonomy: Array[String] = []:
	set(value):
		autonomy = value
		_property_updated(&"autonomy")

## Actions requiring LLM supervisor approval.
var requires_supervisor: Array[String] = []:
	set(value):
		requires_supervisor = value
		_property_updated(&"requires_supervisor")

## Actions requiring human approval.
var requires_human: Array[String] = []:
	set(value):
		requires_human = value
		_property_updated(&"requires_human")

## Per-agent regex additions to global deny list (additive only).
var codetools_deny: Array[String] = []:
	set(value):
		codetools_deny = value
		_property_updated(&"codetools_deny")


# -- Lifecycle ----------------------------------------------------------------

func _init(optional_agent_id: String = ""):
	if optional_agent_id.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		agent_id = str(rng.randi()).sha256_text()
	else:
		agent_id = optional_agent_id


func _property_updated(prop_name: StringName) -> void:
	changed.emit(prop_name)


# -- Serialization ------------------------------------------------------------

## Serialize only Core fields — for sending to backend.
func Serialize() -> Dictionary:
	var data := {
		"name": name,
		"prompt": prompt,
		"tools_enabled": tools_enabled,
	}
	if not agent_id.is_empty():
		data["agent_id"] = agent_id
	if not setup_commands.is_empty():
		data["setup_commands"] = Array(setup_commands)
	if not model.is_empty():
		data["model"] = model
	return data


## Serialize all fields — for client-side persistence.
func SerializeFull() -> Dictionary:
	var data := Serialize()
	if not address.is_empty():
		data["address"] = address
	if not docket.is_empty():
		data["docket"] = docket
	if not notes_thread.is_empty():
		data["notes_thread"] = notes_thread
	if not skills_thread.is_empty():
		data["skills_thread"] = skills_thread
	if not parent.is_empty():
		data["parent"] = parent
	if role != "agent":
		data["role"] = role
	if not autonomy.is_empty():
		data["autonomy"] = Array(autonomy)
	if not requires_supervisor.is_empty():
		data["requires_supervisor"] = Array(requires_supervisor)
	if not requires_human.is_empty():
		data["requires_human"] = Array(requires_human)
	if not codetools_deny.is_empty():
		data["codetools_deny"] = Array(codetools_deny)
	return data


## Deserialize from a dictionary (handles both Core and full dicts).
static func Deserialize(data: Dictionary) -> AgentDefinition:
	var def := AgentDefinition.new(data.get("agent_id", ""))
	def.name = data.get("name", "")
	def.prompt = data.get("prompt", "")
	def.model = data.get("model", "")
	def.tools_enabled = data.get("tools_enabled", false)

	var cmds = data.get("setup_commands", [])
	if cmds is Array:
		var typed: Array[String] = []
		for c in cmds:
			typed.append(str(c))
		def.setup_commands = typed

	# Swarm fields (silently ignored if not present)
	def.address = data.get("address", "")
	def.docket = data.get("docket", "")
	def.notes_thread = data.get("notes_thread", "")
	def.skills_thread = data.get("skills_thread", "")
	def.parent = data.get("parent", "")
	def.role = data.get("role", "agent")

	for field in ["autonomy", "requires_supervisor", "requires_human", "codetools_deny"]:
		var arr = data.get(field, [])
		if arr is Array:
			var typed: Array[String] = []
			for item in arr:
				typed.append(str(item))
			def.set(field, typed)

	return def
