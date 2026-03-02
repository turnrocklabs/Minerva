extends SceneTree
## Unit tests for AgentDefinition Serialize/Deserialize.
## Run: godot --headless --path <minerva/src> --main-loop res://test/test_agent_definition.gd

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("\n===== AgentDefinition Tests =====\n")

	test_serialize_core_only()
	test_serialize_full()
	test_deserialize_core_roundtrip()
	test_deserialize_full_roundtrip()
	test_deserialize_missing_swarm_defaults()
	test_deserialize_old_backend_dict()
	test_swarm_fields_not_in_serialize()
	test_init_generates_id()
	test_init_with_explicit_id()

	print("\n===== Results: %d passed, %d failed =====" % [_pass, _fail])
	if _fail > 0:
		print("******** FAILED ********")
	quit(1 if _fail > 0 else 0)


func _assert(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % label)
	else:
		_fail += 1
		print("  FAIL: %s" % label)


func _assert_eq(actual, expected, label: String) -> void:
	if typeof(actual) == typeof(expected) and actual == expected:
		_pass += 1
		print("  PASS: %s" % label)
	else:
		_fail += 1
		print("  FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])


# -- Tests --------------------------------------------------------------------

func test_serialize_core_only() -> void:
	print("test_serialize_core_only:")
	var def := AgentDefinition.new("test-id-123")
	def.name = "Test Agent"
	def.prompt = "You are a test agent"
	def.model = "anthropic/claude-sonnet-4"
	def.tools_enabled = true
	def.setup_commands = ["cd /tmp", "ls"]
	# Set swarm fields
	def.address = "tester"
	def.docket = "/tmp/test.dct"
	def.role = "supervisor"
	def.parent = "parent-id"

	var data := def.Serialize()

	_assert(data.has("agent_id"), "has agent_id")
	_assert_eq(data["agent_id"], "test-id-123", "agent_id value")
	_assert_eq(data["name"], "Test Agent", "name value")
	_assert_eq(data["prompt"], "You are a test agent", "prompt value")
	_assert_eq(data["model"], "anthropic/claude-sonnet-4", "model value")
	_assert_eq(data["tools_enabled"], true, "tools_enabled value")
	_assert(data.has("setup_commands"), "has setup_commands")
	_assert_eq(data["setup_commands"].size(), 2, "setup_commands count")

	# Swarm fields must NOT be in Serialize()
	_assert(not data.has("address"), "no address in Serialize")
	_assert(not data.has("docket"), "no docket in Serialize")
	_assert(not data.has("role"), "no role in Serialize")
	_assert(not data.has("parent"), "no parent in Serialize")


func test_serialize_full() -> void:
	print("test_serialize_full:")
	var def := AgentDefinition.new("full-test")
	def.name = "Full Agent"
	def.prompt = "prompt"
	def.address = "fullagent"
	def.docket = "/data/full.dct"
	def.notes_thread = "research-tab"
	def.skills_thread = "skills-tab"
	def.parent = "supervisor-1"
	def.role = "supervisor"
	def.autonomy = ["read", "search"]
	def.requires_supervisor = ["write"]
	def.requires_human = ["deploy"]
	def.codetools_deny = ["rm -rf"]

	var data := def.SerializeFull()

	# Core fields present
	_assert(data.has("name"), "has name")
	# Swarm fields present
	_assert_eq(data["address"], "fullagent", "address")
	_assert_eq(data["docket"], "/data/full.dct", "docket")
	_assert_eq(data["notes_thread"], "research-tab", "notes_thread")
	_assert_eq(data["skills_thread"], "skills-tab", "skills_thread")
	_assert_eq(data["parent"], "supervisor-1", "parent")
	_assert_eq(data["role"], "supervisor", "role")
	_assert_eq(data["autonomy"].size(), 2, "autonomy count")
	_assert_eq(data["requires_supervisor"].size(), 1, "requires_supervisor count")
	_assert_eq(data["requires_human"].size(), 1, "requires_human count")
	_assert_eq(data["codetools_deny"].size(), 1, "codetools_deny count")


func test_deserialize_core_roundtrip() -> void:
	print("test_deserialize_core_roundtrip:")
	var original := AgentDefinition.new("rt-core")
	original.name = "Roundtrip"
	original.prompt = "test prompt"
	original.model = "openai/gpt-4"
	original.tools_enabled = true
	original.setup_commands = ["npm install"]

	var data := original.Serialize()
	var restored := AgentDefinition.Deserialize(data)

	_assert_eq(restored.agent_id, "rt-core", "agent_id roundtrip")
	_assert_eq(restored.name, "Roundtrip", "name roundtrip")
	_assert_eq(restored.prompt, "test prompt", "prompt roundtrip")
	_assert_eq(restored.model, "openai/gpt-4", "model roundtrip")
	_assert_eq(restored.tools_enabled, true, "tools_enabled roundtrip")
	_assert_eq(restored.setup_commands.size(), 1, "setup_commands roundtrip")
	_assert_eq(restored.setup_commands[0], "npm install", "setup_commands[0] roundtrip")


func test_deserialize_full_roundtrip() -> void:
	print("test_deserialize_full_roundtrip:")
	var original := AgentDefinition.new("rt-full")
	original.name = "Full RT"
	original.prompt = "full prompt"
	original.address = "fullrt"
	original.docket = "/d/test.dct"
	original.parent = "boss"
	original.role = "supervisor"
	original.autonomy = ["read"]
	original.requires_human = ["deploy", "delete"]
	original.codetools_deny = ["curl POST"]

	var data := original.SerializeFull()
	var restored := AgentDefinition.Deserialize(data)

	_assert_eq(restored.agent_id, "rt-full", "agent_id")
	_assert_eq(restored.address, "fullrt", "address roundtrip")
	_assert_eq(restored.docket, "/d/test.dct", "docket roundtrip")
	_assert_eq(restored.parent, "boss", "parent roundtrip")
	_assert_eq(restored.role, "supervisor", "role roundtrip")
	_assert_eq(restored.autonomy.size(), 1, "autonomy roundtrip")
	_assert_eq(restored.requires_human.size(), 2, "requires_human roundtrip")
	_assert_eq(restored.codetools_deny[0], "curl POST", "codetools_deny roundtrip")


func test_deserialize_missing_swarm_defaults() -> void:
	print("test_deserialize_missing_swarm_defaults:")
	# Simulate a dict from Core that has no swarm fields
	var data := {
		"agent_id": "core-only",
		"name": "Core Agent",
		"prompt": "basic",
		"tools_enabled": false,
	}
	var def := AgentDefinition.Deserialize(data)

	_assert_eq(def.agent_id, "core-only", "agent_id")
	_assert_eq(def.name, "Core Agent", "name")
	_assert_eq(def.role, "agent", "default role is agent")
	_assert_eq(def.address, "", "default address empty")
	_assert_eq(def.docket, "", "default docket empty")
	_assert_eq(def.parent, "", "default parent empty")
	_assert_eq(def.autonomy.size(), 0, "default autonomy empty")
	_assert_eq(def.requires_supervisor.size(), 0, "default requires_supervisor empty")
	_assert_eq(def.requires_human.size(), 0, "default requires_human empty")
	_assert_eq(def.codetools_deny.size(), 0, "default codetools_deny empty")


func test_deserialize_old_backend_dict() -> void:
	print("test_deserialize_old_backend_dict:")
	# Exact shape returned by AutocoderAdapter.list_review_agents()
	var data := {
		"agent_id": "agent_abc123",
		"name": "Code Reviewer",
		"prompt": "Review this code for bugs",
		"model": "anthropic/claude-sonnet-4",
		"tools_enabled": true,
		"setup_commands": ["cd project", "git status"],
	}
	var def := AgentDefinition.Deserialize(data)

	_assert_eq(def.agent_id, "agent_abc123", "agent_id from backend")
	_assert_eq(def.name, "Code Reviewer", "name from backend")
	_assert_eq(def.prompt, "Review this code for bugs", "prompt from backend")
	_assert_eq(def.model, "anthropic/claude-sonnet-4", "model from backend")
	_assert_eq(def.tools_enabled, true, "tools_enabled from backend")
	_assert_eq(def.setup_commands.size(), 2, "setup_commands from backend")
	# Swarm fields should have safe defaults
	_assert_eq(def.role, "agent", "default role")
	_assert_eq(def.parent, "", "no parent")


func test_swarm_fields_not_in_serialize() -> void:
	print("test_swarm_fields_not_in_serialize:")
	var def := AgentDefinition.new("leak-test")
	def.name = "Leak Test"
	def.prompt = "test"
	def.address = "leaker"
	def.docket = "/secret/path.dct"
	def.notes_thread = "notes"
	def.skills_thread = "skills"
	def.parent = "boss"
	def.role = "supervisor"
	def.autonomy = ["everything"]
	def.requires_supervisor = ["nothing"]
	def.requires_human = ["approval"]
	def.codetools_deny = ["rm"]

	var core_data := def.Serialize()

	var swarm_keys := ["address", "docket", "notes_thread", "skills_thread",
		"parent", "role", "autonomy", "requires_supervisor",
		"requires_human", "codetools_deny"]

	for key in swarm_keys:
		_assert(not core_data.has(key), "Serialize() must not contain '%s'" % key)


func test_init_generates_id() -> void:
	print("test_init_generates_id:")
	var def := AgentDefinition.new()
	_assert(not def.agent_id.is_empty(), "auto-generated id is not empty")
	_assert(def.agent_id.length() == 64, "auto-generated id is SHA256 (64 chars)")


func test_init_with_explicit_id() -> void:
	print("test_init_with_explicit_id:")
	var def := AgentDefinition.new("my-custom-id")
	_assert_eq(def.agent_id, "my-custom-id", "explicit id preserved")
