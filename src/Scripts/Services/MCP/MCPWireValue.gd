class_name MCPWireValue
extends RefCounted
## Original UTF-8 plus its decoded view. Transports may forward raw_utf8; an
## application adapter must validate numeric compatibility before using parsed.

var raw_utf8 := ""
var parsed: Variant

static func create(raw: String, decoded: Variant):
	var value = load("res://Scripts/Services/MCP/MCPWireValue.gd").new()
	value.raw_utf8 = raw
	value.parsed = decoded
	return value

func forwarding_bytes() -> PackedByteArray:
	return raw_utf8.to_utf8_buffer()
