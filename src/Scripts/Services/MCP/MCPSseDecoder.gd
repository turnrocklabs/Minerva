extends RefCounted
## Byte-oriented SSE framing keeps incomplete UTF-8 sequences intact until an
## event is complete. Reconnection and Last-Event-ID replay are deliberately absent.
const MAX_EVENT_BYTES := 32 * 1024 * 1024
const MAX_TOTAL_BYTES := 64 * 1024 * 1024
var buffer := PackedByteArray()
var data := PackedByteArray()
var total := 0
var events := 0
var error := ""
var _skip_lf := false
var _first_line := true

func feed(chunk: PackedByteArray) -> Array[PackedByteArray]:
	var output: Array[PackedByteArray] = []
	total += chunk.size()
	if total > MAX_TOTAL_BYTES:
		error = "SSE response exceeds byte budget"
		return output
	for byte: int in chunk:
		if _skip_lf:
			_skip_lf = false
			if byte == 10:
				continue
		if byte == 13 or byte == 10:
			_skip_lf = byte == 13
			if _first_line:
				_first_line = false
				if buffer.slice(0, 3) == PackedByteArray([239, 187, 191]):
					buffer = buffer.slice(3)
			if buffer.is_empty():
				if not data.is_empty():
					data.resize(data.size() - 1)
					output.append(data)
					data = PackedByteArray()
					events += 1
					if events > 4096:
						error = "SSE response exceeds event budget"
						return output
			elif buffer.slice(0, 5) == "data:".to_utf8_buffer():
				var value := buffer.slice(5)
				if not value.is_empty() and value[0] == 32:
					value = value.slice(1)
				data.append_array(value)
				data.append(10)
			buffer = PackedByteArray()
		else:
			buffer.append(byte)
		if buffer.size() + data.size() > MAX_EVENT_BYTES:
			error = "SSE event exceeds byte budget"
			return output
	return output
