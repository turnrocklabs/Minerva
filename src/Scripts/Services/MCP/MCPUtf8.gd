extends RefCounted
## Strict UTF-8 validation before Godot is asked to decode untrusted bytes.

static func is_valid(bytes: PackedByteArray) -> bool:
	var index := 0
	while index < bytes.size():
		var first: int = bytes[index]
		# Godot strings truncate at NUL during UTF-8 construction, so this valid
		# Unicode scalar is unsupported at the untrusted byte boundary.
		if first == 0:
			return false
		if first <= 0x7f:
			index += 1
			continue
		var length := 0
		var second_min := 0x80
		var second_max := 0xbf
		if first >= 0xc2 and first <= 0xdf:
			length = 2
		elif first >= 0xe0 and first <= 0xef:
			length = 3
			if first == 0xe0:
				second_min = 0xa0
			elif first == 0xed:
				second_max = 0x9f
		elif first >= 0xf0 and first <= 0xf4:
			length = 4
			if first == 0xf0:
				second_min = 0x90
			elif first == 0xf4:
				second_max = 0x8f
		else:
			return false
		if index + length > bytes.size():
			return false
		var second: int = bytes[index + 1]
		if second < second_min or second > second_max:
			return false
		for offset in range(2, length):
			var continuation: int = bytes[index + offset]
			if continuation < 0x80 or continuation > 0xbf:
				return false
		index += length
	return true
