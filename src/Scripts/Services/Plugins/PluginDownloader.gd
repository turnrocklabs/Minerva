extends RefCounted
## Streams a plugin archive to a file over HTTP(S). Used by
## MarketplaceClient.install_from_url.
##
## A slow download never fails for taking long; it fails only when no byte
## arrives for `stall_timeout_s`. A dropped or stalled transfer resumes with
## an HTTP Range request from the bytes already written. A server that
## answers that Range with anything but the matching 206 cannot resume: the
## partial file is deleted and the result is download_resume_unsupported.
## After MAX_FRUITLESS_ATTEMPTS attempts in a row that add no bytes, the
## download gives up with the last attempt's error.
##
## The transfer runs on a worker thread that drains what the socket holds
## and sleeps IDLE_MS when nothing has arrived, so a waiting transfer costs
## little CPU and the rate does not depend on the frame rate (a busy or
## slow-rendering UI would otherwise throttle it). The caller's thread only
## mirrors progress into `op` once a frame. The expectation, that this beats
## threaded HTTPRequest (whose worker appears to spin between polls), is what
## scripts/bench-plugin-download-cpu.sh measures.
##
## Results use MarketplaceClient's shape: {ok:true, bytes} or
## {ok:false, error, detail}.

const Operation := preload("res://Scripts/Services/Plugins/PluginInstallOperation.gd")

const MAX_REDIRECTS := 10
const MAX_FRUITLESS_ATTEMPTS := 3
const IDLE_MS := 5
const CHUNK_BYTES := 256 * 1024
const URL_RE := "^(https?)://([^/:?#]+)(?::(\\d+))?([^#]*)"

var stall_timeout_s: float = 30.0
var max_bytes: int = 0  # 0 = no limit
## Final once download() returns; while it runs they belong to the worker,
## and progress reaches `op` through the snapshot below.
var bytes_received: int = 0
var bytes_total: int = -1  # -1 until the server states a length
## A PluginInstallOperation to report bytes to and to stop on cancel; optional.
var op: Operation = null


# What crosses between the worker and the caller's thread, under _lock: the
# worker's progress, published as it changes, and a cancel request.
var _lock := Mutex.new()
var _shared_done := 0
var _shared_total := -1
var _stop := false
# The thread lives as long as this downloader, not the caller's coroutine,
# and is let go only after it has been waited for.
var _worker: Thread = null


func download(url: String, dest_path: String, tree: SceneTree) -> Dictionary:
	var file := FileAccess.open(dest_path, FileAccess.WRITE)
	if file == null:
		return _result("download_write_failed", {"path": dest_path, "godot_err": FileAccess.get_open_error()})
	var outcome := {}
	_worker = Thread.new()
	var started := _worker.start(_transfer.bind(url, file, outcome))
	if started != OK:
		_worker = null
		file.close()
		DirAccess.remove_absolute(dest_path)
		return {"ok": false, "error": "download_request_failed",
			"detail": {"url": url, "reason": "the download thread could not start", "godot_err": started}}
	while _worker.is_alive():
		if op != null:
			_lock.lock()
			_stop = op.cancelled
			op.done = _shared_done
			op.total = _shared_total
			_lock.unlock()
		await tree.process_frame
	_worker.wait_to_finish()
	_worker = null
	if op != null:
		op.done = bytes_received
		op.total = bytes_total
	file.close()
	outcome.erase("retry")
	if not outcome.get("ok", false):
		DirAccess.remove_absolute(dest_path)
	return outcome


## The worker: attempts until one completes, fails for good, or several in a
## row add no bytes. Fills `outcome`.
func _transfer(url: String, file: FileAccess, outcome: Dictionary) -> void:
	var fruitless := 0
	while fruitless < MAX_FRUITLESS_ATTEMPTS:
		var before := bytes_received
		outcome.clear()
		outcome.merge(_attempt(url, file))
		if outcome.get("ok", false) or not outcome.get("retry", false):
			return
		fruitless = 0 if bytes_received > before else fruitless + 1


## One request, following redirects, that appends to `file` from
## bytes_received. A failure marked `retry` may be resumed.
func _attempt(url: String, file: FileAccess) -> Dictionary:
	var target := url
	for _hop in MAX_REDIRECTS + 1:
		var outcome := _exchange(target, file)
		if not outcome.has("redirect"):
			return outcome
		target = outcome.redirect
	return _result("download_redirect_limit", {"url": url})


func _exchange(url: String, file: FileAccess) -> Dictionary:
	var re := RegEx.create_from_string(URL_RE)
	var m := re.search(url)
	if m == null:
		return _result("download_request_failed", {"url": url, "reason": "unsupported URL"})
	var tls := m.get_string(1) == "https"
	var port := int(m.get_string(3)) if not m.get_string(3).is_empty() else (443 if tls else 80)
	var path := m.get_string(4)
	if not path.begins_with("/"):
		path = "/" + path  # "" or a bare "?query"

	var client := HTTPClient.new()
	client.read_chunk_size = CHUNK_BYTES
	var err := client.connect_to_host(m.get_string(2), port, TLSOptions.client() if tls else null)
	if err != OK:
		return _result("download_request_failed", {"url": url, "godot_err": err})
	var outcome := _pump(client, url, path, file)
	client.close()
	return outcome


func _pump(client: HTTPClient, url: String, path: String, file: FileAccess) -> Dictionary:
	var status := -1
	var requested := false
	var answered := false
	var last_progress := Time.get_ticks_msec()
	while true:
		client.poll()
		if client.get_status() != status:
			status = client.get_status()
			last_progress = Time.get_ticks_msec()
		# A response with no body goes straight back to CONNECTED, so the
		# answer is judged here rather than on entering BODY.
		if requested and not answered and client.has_response():
			answered = true
			var verdict := _accept_response(client, url)
			if not verdict.is_empty():
				return verdict
		match status:
			HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, \
					HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
				return _result("download_connection_failed", {"url": url, "status": status}, true)
			HTTPClient.STATUS_CONNECTED:
				if answered:
					return _finished(url, status)
				if not requested:
					var headers := PackedStringArray(["User-Agent: Minerva", "Accept-Encoding: identity"])
					if bytes_received > 0:
						headers.append("Range: bytes=%d-" % bytes_received)
					var err := client.request(HTTPClient.METHOD_GET, path, headers)
					if err != OK:
						return _result("download_request_failed", {"url": url, "godot_err": err})
					requested = true
			HTTPClient.STATUS_BODY:
				while client.get_status() == HTTPClient.STATUS_BODY:
					if _stopping():
						return _result("cancelled", {})
					var chunk := client.read_response_body_chunk()
					if chunk.is_empty():
						break
					if not file.store_buffer(chunk):
						return _result("download_write_failed", {"path": file.get_path_absolute(), "godot_err": file.get_error()})
					bytes_received += chunk.size()
					_publish()
					last_progress = Time.get_ticks_msec()
					if max_bytes > 0 and bytes_received > max_bytes:
						return _result("download_too_large", {"url": url, "limit": max_bytes})
					client.poll()
			HTTPClient.STATUS_DISCONNECTED, HTTPClient.STATUS_CONNECTION_ERROR:
				if answered:
					return _finished(url, status)
				return _result("download_interrupted", {"url": url, "bytes": bytes_received, "total": bytes_total}, true)
		if _stopping():
			return _result("cancelled", {})
		if Time.get_ticks_msec() - last_progress > stall_timeout_s * 1000.0:
			return _result("download_stalled", {"url": url, "seconds": stall_timeout_s, "bytes": bytes_received, "total": bytes_total}, true)
		# The body may have ended during the drain; judge that without waiting.
		if status != HTTPClient.STATUS_BODY or client.get_status() == HTTPClient.STATUS_BODY:
			OS.delay_msec(IDLE_MS)
	return {}


## Judge the status line and headers. Returns {} to read the body, or
## the result to end this exchange with.
func _accept_response(client: HTTPClient, url: String) -> Dictionary:
	var code := client.get_response_code()
	var headers := {}
	for line in client.get_response_headers():
		var colon := line.find(":")
		if colon > 0:
			headers[line.substr(0, colon).strip_edges().to_lower()] = line.substr(colon + 1).strip_edges()
	if code in [301, 302, 303, 307, 308] and headers.has("location"):
		return {"redirect": _resolve(url, headers["location"])}
	if code == 200:
		if bytes_received > 0:
			return _result("download_resume_unsupported", {"url": url, "bytes": bytes_received})
		bytes_total = client.get_response_body_length()
	elif code == 206 and bytes_received > 0:
		# Content-Range: bytes <first>-<last>/<total>
		var range_re := RegEx.create_from_string("bytes (\\d+)-\\d+/(\\d+)")
		var m := range_re.search(str(headers.get("content-range", "")))
		# A changed total means the asset changed between attempts.
		if m == null or int(m.get_string(1)) != bytes_received \
				or (bytes_total >= 0 and int(m.get_string(2)) != bytes_total):
			return _result("download_resume_unsupported", {"url": url, "bytes": bytes_received,
				"content_range": headers.get("content-range", "")})
		bytes_total = int(m.get_string(2))
	else:
		return _result("download_bad_status", {"code": code, "url": url})
	_publish()
	if max_bytes > 0 and bytes_total > max_bytes:
		return _result("download_too_large", {"url": url, "limit": max_bytes, "total": bytes_total})
	return {}


## Worker side: share the byte counts with the caller's thread.
func _publish() -> void:
	_lock.lock()
	_shared_done = bytes_received
	_shared_total = bytes_total
	_lock.unlock()


## Worker side: whether the caller has asked to stop.
func _stopping() -> bool:
	_lock.lock()
	var stop := _stop
	_lock.unlock()
	return stop


## The body ended: complete when the stated length arrived, or when no
## length was stated and the connection closed cleanly.
func _finished(url: String, status: int) -> Dictionary:
	var complete := bytes_received == bytes_total if bytes_total >= 0 \
			else status != HTTPClient.STATUS_CONNECTION_ERROR
	if complete:
		return {"ok": true, "bytes": bytes_received}
	return _result("download_interrupted", {"url": url, "bytes": bytes_received, "total": bytes_total}, true)


## Absolute, protocol-relative, root-relative, query-only, or
## directory-relative Location against the URL that answered with it.
static func _resolve(base: String, location: String) -> String:
	if location.begins_with("http://") or location.begins_with("https://"):
		return location
	var m := RegEx.create_from_string("^(https?:)(//[^/?#]+)([^?#]*/)?").search(base)
	if location.begins_with("?"):
		return base.get_slice("?", 0).get_slice("#", 0) + location
	if location.begins_with("//"):
		return m.get_string(1) + location
	if location.begins_with("/"):
		return m.get_string(1) + m.get_string(2) + location
	var dir := m.get_string(3) if not m.get_string(3).is_empty() else "/"
	return m.get_string(1) + m.get_string(2) + dir + location


static func _result(code: String, detail: Dictionary, retry: bool = false) -> Dictionary:
	return {"ok": false, "error": code, "detail": detail, "retry": retry}
