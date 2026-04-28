class_name MCPHttpTools
extends MCPToolModule
## MCP tool module for outbound HTTP requests.
## Enforces a deny-by-default policy on private/loopback hosts and
## applies a per-host token-bucket rate limit (10 req/s, cap 10).

# Per-host token bucket state: { hostname -> {tokens: float, last_refill_ms: int} }
var _buckets: Dictionary = {}

# Allow-list for private/loopback hosts that would otherwise be blocked.
# Set programmatically before making a request. A policy-file integration
# could populate this on startup.
# TODO: load from a policy file (e.g. user://http_allowlist.cfg) at init time.
var _allow_hosts: Array[String] = []

const _BUCKET_CAPACITY: float = 10.0
const _BUCKET_REFILL_RATE: float = 10.0  # tokens per second
const _RATE_LIMIT_WAIT_MS: int = 5000


func get_tool_names() -> Array[String]:
	return ["minerva_http_request"]


func register_tools() -> void:
	server._register_tool(
		"minerva_http_request",
		"Make an outbound HTTP request. Supports GET, POST, PUT, DELETE, PATCH. " +
		"Private/loopback hosts are blocked by default (override via _allow_hosts in code). " +
		"Rate limited to 10 requests/second per host (token bucket, cap 10). " +
		"Returns {status, headers, body} on success, or {error: {kind, message, retriable}} on failure.",
		{
			"type": "object",
			"properties": {
				"method": {
					"type": "string",
					"enum": ["GET", "POST", "PUT", "DELETE", "PATCH"],
					"description": "HTTP method."
				},
				"url": {
					"type": "string",
					"description": "Full URL including scheme."
				},
				"headers": {
					"type": "object",
					"description": "Optional request headers as key/value pairs."
				},
				"body": {
					"description": "Optional request body. Dictionaries are JSON-encoded and Content-Type is set automatically.",
				},
				"timeout_ms": {
					"type": "integer",
					"description": "Request timeout in milliseconds (default 30000)."
				},
				"response_format": {
					"type": "string",
					"enum": ["json", "text"],
					"description": "How to parse the response body (default 'json')."
				},
			},
			"required": ["method", "url"],
		},
		"http"
	)


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_http_request": return await _http_request(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


# ---------------------------------------------------------------------------
# Core handler
# ---------------------------------------------------------------------------

func _http_request(args: Dictionary) -> Dictionary:
	var url: String = args.get("url", "")
	if url.is_empty():
		return MCPToolUtils.error("url is required")

	var method_str: String = (args.get("method", "GET") as String).to_upper()
	var timeout_ms: int = MCPToolUtils.coerce_int(args.get("timeout_ms", 30000))
	var response_format: String = args.get("response_format", "json")

	# --- parse host from URL ---
	var host: String = _parse_host(url)
	if host.is_empty():
		return MCPToolUtils.error("Could not parse host from URL: %s" % url)

	# --- policy check ---
	var policy_err: Dictionary = _check_policy(host)
	if not policy_err.is_empty():
		return policy_err

	# --- rate limit ---
	var rate_err: Dictionary = await _acquire_token(host)
	if not rate_err.is_empty():
		return rate_err

	# --- build headers ---
	var raw_headers: Dictionary = MCPToolUtils.coerce_object(args.get("headers", {}))
	var body_arg = args.get("body", null)
	var body_str: String = ""

	if body_arg != null:
		if body_arg is Dictionary:
			body_str = JSON.stringify(body_arg)
			if not _headers_have_key(raw_headers, "content-type"):
				raw_headers["Content-Type"] = "application/json"
		else:
			body_str = str(body_arg)

	var header_array: PackedStringArray = []
	for k in raw_headers:
		header_array.append("%s: %s" % [k, raw_headers[k]])

	# --- map method ---
	var http_method: int = _map_method(method_str)

	# --- execute ---
	return await _do_request(url, http_method, header_array, body_str, timeout_ms, response_format)


# ---------------------------------------------------------------------------
# HTTPRequest execution (fresh node per call)
# ---------------------------------------------------------------------------

func _do_request(
	url: String,
	method: int,
	headers: PackedStringArray,
	body: String,
	timeout_ms: int,
	response_format: String
) -> Dictionary:
	var http: HTTPRequest = HTTPRequest.new()
	http.use_threads = true
	http.timeout = timeout_ms / 1000.0

	# Need a scene-tree node to attach to; use the server if it's a Node, else
	# fall back to the scene root via SingletonObject.
	var parent: Node = _get_attachment_parent()
	parent.add_child(http)

	var completed := {"fired": false, "result": -1, "code": -1, "resp_headers": [], "body": PackedByteArray()}
	var on_done := func(result: int, response_code: int, resp_headers: PackedStringArray, resp_body: PackedByteArray) -> void:
		completed["fired"] = true
		completed["result"] = result
		completed["code"] = response_code
		completed["resp_headers"] = resp_headers
		completed["body"] = resp_body

	http.request_completed.connect(on_done)

	var err: int
	if body.is_empty():
		err = http.request(url, headers, method)
	else:
		err = http.request(url, headers, method, body)

	if err != OK:
		http.queue_free()
		return _err_envelope("connection_refused", "HTTPRequest.request() failed with error %d" % err, true)

	# Poll until the signal fires (the signal is emitted on the main thread via
	# use_threads, so awaiting process_frame is sufficient).
	var start_ms: int = Time.get_ticks_msec()
	while not completed["fired"]:
		if Time.get_ticks_msec() - start_ms > (timeout_ms + 2000):
			# Safety bail-out beyond the node's own timeout.
			http.cancel_request()
			http.queue_free()
			return _err_envelope("timeout", "Request exceeded timeout (%d ms)" % timeout_ms, true)
		await parent.get_tree().process_frame

	http.request_completed.disconnect(on_done)
	http.queue_free()

	return _process_response(
		completed["result"] as int,
		completed["code"] as int,
		completed["resp_headers"] as PackedStringArray,
		completed["body"] as PackedByteArray,
		response_format
	)


func _process_response(
	result: int,
	status_code: int,
	resp_headers: PackedStringArray,
	body_bytes: PackedByteArray,
	response_format: String
) -> Dictionary:
	# Map Godot RESULT_* codes to structured errors.
	match result:
		HTTPRequest.RESULT_TIMEOUT:
			return _err_envelope("timeout", "Request timed out", true)
		HTTPRequest.RESULT_CANT_CONNECT:
			return _err_envelope("connection_refused", "Could not connect to host", true)
		HTTPRequest.RESULT_CANT_RESOLVE:
			return _err_envelope("dns_failure", "DNS resolution failed", true)
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return _err_envelope("tls_error", "TLS handshake failed", false)
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return _err_envelope("connection_refused", "Connection error", true)
		HTTPRequest.RESULT_NO_RESPONSE:
			return _err_envelope("connection_refused", "No response from server", true)

	if result != HTTPRequest.RESULT_SUCCESS:
		return _err_envelope("connection_refused", "HTTPRequest failed (result=%d)" % result, true)

	# Parse headers into dict
	var headers_dict: Dictionary = {}
	for h in resp_headers:
		var idx: int = h.find(": ")
		if idx > 0:
			headers_dict[h.substr(0, idx).to_lower()] = h.substr(idx + 2)

	# Parse body
	var body_text: String = body_bytes.get_string_from_utf8()
	var parsed_body = body_text

	if response_format == "json":
		var json_result = JSON.parse_string(body_text)
		if json_result == null:
			# JSON parse failed — return raw with an error field
			var error_envelope: Dictionary = {
				"status": status_code,
				"headers": headers_dict,
				"body": body_text,
				"error": {
					"kind": "invalid_response",
					"message": "Response body is not valid JSON",
					"retriable": false,
				}
			}
			if status_code < 200 or status_code >= 300:
				error_envelope["error"] = {
					"kind": "http_error",
					"message": "HTTP %d with non-JSON body" % status_code,
					"retriable": status_code >= 500 and status_code < 600,
				}
			return error_envelope
		parsed_body = json_result

	var envelope: Dictionary = {
		"status": status_code,
		"headers": headers_dict,
		"body": parsed_body,
	}

	if status_code < 200 or status_code >= 300:
		envelope["error"] = {
			"kind": "http_error",
			"message": "HTTP %d" % status_code,
			"retriable": status_code >= 500 and status_code < 600,
		}

	return envelope


# ---------------------------------------------------------------------------
# Host policy
# ---------------------------------------------------------------------------

func _check_policy(host: String) -> Dictionary:
	if host in _allow_hosts:
		return {}

	# Resolve to IP for additional checks (may return empty on failure — handled later).
	var resolved: String = IP.resolve_hostname(host, IP.TYPE_ANY)

	# Check hostname patterns first.
	if _is_blocked_hostname(host):
		return _policy_denied(host)

	# Check resolved IP.
	if not resolved.is_empty() and _is_blocked_ip(resolved):
		return _policy_denied(host)

	return {}


func _is_blocked_hostname(host: String) -> bool:
	if host == "localhost":
		return true
	if host.ends_with(".local"):
		return true
	if host.ends_with(".internal"):
		return true
	return false


func _is_blocked_ip(ip: String) -> bool:
	# IPv6 loopback and private ranges.
	if ip == "::1":
		return true
	if ip.begins_with("fc") or ip.begins_with("fd"):
		# fc00::/7 — covers fc** and fd**
		return true
	if ip.begins_with("fe80"):
		# fe80::/10
		return true

	# IPv4: parse to 32-bit integer for CIDR checks.
	var parts: PackedStringArray = ip.split(".")
	if parts.size() != 4:
		return false  # IPv6 non-loopback, allow

	var n: int = 0
	for i in range(4):
		if not parts[i].is_valid_int():
			return false
		var octet: int = parts[i].to_int()
		if octet < 0 or octet > 255:
			return false
		n = (n << 8) | octet

	# 127.0.0.0/8
	if (n >> 24) == 127:
		return true
	# 10.0.0.0/8
	if (n >> 24) == 10:
		return true
	# 172.16.0.0/12
	if (n >> 20) == (172 << 4 | 1):
		return true
	# 192.168.0.0/16
	if (n >> 16) == (192 << 8 | 168):
		return true
	# 169.254.0.0/16 (link-local)
	if (n >> 16) == (169 << 8 | 254):
		return true

	return false


func _policy_denied(host: String) -> Dictionary:
	return {
		"error": {
			"kind": "policy_denied",
			"message": "Host '%s' blocked by policy (private/loopback). Override via _allow_hosts." % host,
			"retriable": false,
		}
	}


# ---------------------------------------------------------------------------
# Rate limiting (token bucket per hostname)
# ---------------------------------------------------------------------------

func _acquire_token(host: String) -> Dictionary:
	var deadline_ms: int = Time.get_ticks_msec() + _RATE_LIMIT_WAIT_MS

	while true:
		_refill_bucket(host)
		var bucket: Dictionary = _buckets[host]

		if bucket["tokens"] >= 1.0:
			bucket["tokens"] -= 1.0
			return {}

		var now_ms: int = Time.get_ticks_msec()
		if now_ms >= deadline_ms:
			# Estimate when next token will be available.
			var deficit: float = 1.0 - bucket["tokens"]
			var retry_after_ms: int = int(ceil(deficit / _BUCKET_REFILL_RATE * 1000.0))
			return {
				"error": {
					"kind": "rate_limited",
					"message": "Rate limit exceeded for host '%s' (10 req/s)." % host,
					"retriable": true,
					"retry_after_ms": retry_after_ms,
				}
			}

		# Wait one frame and retry.
		await _get_attachment_parent().get_tree().process_frame

	# Unreachable, but GDScript needs a return.
	return {}


func _refill_bucket(host: String) -> void:
	var now_ms: int = Time.get_ticks_msec()
	if not _buckets.has(host):
		_buckets[host] = {"tokens": _BUCKET_CAPACITY, "last_refill_ms": now_ms}
		return
	var bucket: Dictionary = _buckets[host]
	var elapsed_s: float = (now_ms - bucket["last_refill_ms"]) / 1000.0
	bucket["tokens"] = minf(
		_BUCKET_CAPACITY,
		bucket["tokens"] + elapsed_s * _BUCKET_REFILL_RATE
	)
	bucket["last_refill_ms"] = now_ms


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _parse_host(url: String) -> String:
	# Strip scheme
	var s: String = url
	var scheme_end: int = s.find("://")
	if scheme_end >= 0:
		s = s.substr(scheme_end + 3)
	# Strip path, query, fragment
	for sep in ["/", "?", "#"]:
		var idx: int = s.find(sep)
		if idx >= 0:
			s = s.substr(0, idx)
	# Strip port
	# Handle IPv6 bracket notation: [::1]:port
	if s.begins_with("["):
		var bracket_end: int = s.find("]")
		if bracket_end >= 0:
			return s.substr(1, bracket_end - 1)
		return ""
	var colon: int = s.rfind(":")
	if colon >= 0:
		s = s.substr(0, colon)
	return s.to_lower()


func _map_method(method_str: String) -> int:
	match method_str:
		"GET":    return HTTPClient.METHOD_GET
		"POST":   return HTTPClient.METHOD_POST
		"PUT":    return HTTPClient.METHOD_PUT
		"DELETE": return HTTPClient.METHOD_DELETE
		"PATCH":  return HTTPClient.METHOD_PATCH
	return HTTPClient.METHOD_GET


func _headers_have_key(headers: Dictionary, lower_key: String) -> bool:
	for k in headers:
		if (k as String).to_lower() == lower_key:
			return true
	return false


func _err_envelope(kind: String, message: String, retriable: bool) -> Dictionary:
	return {
		"error": {
			"kind": kind,
			"message": message,
			"retriable": retriable,
		}
	}


func _get_attachment_parent() -> Node:
	# Prefer server if it's a Node (it usually is — MinervaMCPServer extends Node).
	if server is Node:
		return server as Node
	# Fallback: attach to the scene root via SingletonObject.
	return SingletonObject.get_tree().get_root()
