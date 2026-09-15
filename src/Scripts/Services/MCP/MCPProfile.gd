class_name MCPProfile
extends RefCounted
## Explicit protocol profiles prevent custom and legacy peers from inheriting a
## modern version label merely because they share a transport implementation.

const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")

enum Era { UNKNOWN, MODERN_2026_07_28, INITIALIZED_LEGACY, CUSTOM }

var era := Era.UNKNOWN
var protocol_version := ""
var capabilities: Dictionary = {}
var generation := 0


static func modern(peer_capabilities: Dictionary, process_generation: int):
	var profile = load("res://Scripts/Services/MCP/MCPProfile.gd").new()
	profile.era = Era.MODERN_2026_07_28
	profile.protocol_version = Protocol.MODERN_VERSION
	profile.capabilities = peer_capabilities.duplicate(true)
	profile.generation = process_generation
	return profile


static func legacy(version: String, peer_capabilities: Dictionary, process_generation: int):
	var profile = load("res://Scripts/Services/MCP/MCPProfile.gd").new()
	profile.era = Era.INITIALIZED_LEGACY
	profile.protocol_version = version
	profile.capabilities = peer_capabilities.duplicate(true)
	profile.generation = process_generation
	return profile


static func custom(process_generation: int):
	var profile = load("res://Scripts/Services/MCP/MCPProfile.gd").new()
	profile.era = Era.CUSTOM
	profile.generation = process_generation
	return profile


func supports(capability: String) -> bool:
	return capabilities.has(capability)
