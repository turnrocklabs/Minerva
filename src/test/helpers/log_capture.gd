extends Logger

var entries: Array[String] = []
var _mutex := Mutex.new()


func _log_message(message: String, _error: bool) -> void:
	_mutex.lock()
	entries.append(message)
	_mutex.unlock()


func _log_error(_function: String, _file: String, _line: int, code: String,
		rationale: String, _editor_notify: bool, _error_type: int,
		_script_backtraces: Array[ScriptBacktrace]) -> void:
	_mutex.lock()
	entries.append(code + " " + rationale)
	_mutex.unlock()


func combined() -> String:
	_mutex.lock()
	var result := "\n".join(entries)
	_mutex.unlock()
	return result


func size() -> int:
	_mutex.lock()
	var result := entries.size()
	_mutex.unlock()
	return result


func since(index: int) -> String:
	_mutex.lock()
	var result := "\n".join(entries.slice(index))
	_mutex.unlock()
	return result
