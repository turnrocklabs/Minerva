class_name ChatGPTAuth
extends RefCounted
## Handles OAuth PKCE authentication against ChatGPT accounts.
## Based on the opencode-openai-codex-auth plugin's OAuth flow.

const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
const AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
const TOKEN_URL = "https://auth.openai.com/oauth/token"
const REDIRECT_URI = "http://localhost:1455/auth/callback"
const SCOPE = "openid profile email offline_access"
const CALLBACK_PORT = 1455

const JWT_CLAIM_PATH = "https://api.openai.com/auth"

## Stored auth state
var access_token: String = ""
var refresh_token: String = ""
var expires_at: int = 0  # Unix timestamp in milliseconds
var account_id: String = ""

## PKCE state (during auth flow)
var _code_verifier: String = ""
var _state: String = ""
var _tcp_server: TCPServer = null

## Whether we're currently in an auth flow
var _auth_in_progress: bool = false

signal auth_completed(success: bool, error_message: String)
signal auth_status_changed(connected: bool)


func is_authenticated() -> bool:
	return not access_token.is_empty() and not account_id.is_empty()


func get_status_text() -> String:
	if not is_authenticated():
		return "Not connected"
	var expires_str := Time.get_datetime_string_from_unix_time(expires_at / 1000, true)
	return "Connected (expires %s)" % expires_str


## Load stored tokens from encrypted config file
func load_tokens() -> void:
	var config: ConfigFile = SingletonObject.preferences_popup.config_file
	access_token = config.get_value("CHATGPT_AUTH", "access_token", "")
	refresh_token = config.get_value("CHATGPT_AUTH", "refresh_token", "")
	expires_at = config.get_value("CHATGPT_AUTH", "expires_at", 0)
	account_id = config.get_value("CHATGPT_AUTH", "account_id", "")


## Save tokens to encrypted config file
func save_tokens() -> void:
	var config: ConfigFile = SingletonObject.preferences_popup.config_file
	config.set_value("CHATGPT_AUTH", "access_token", access_token)
	config.set_value("CHATGPT_AUTH", "refresh_token", refresh_token)
	config.set_value("CHATGPT_AUTH", "expires_at", expires_at)
	config.set_value("CHATGPT_AUTH", "account_id", account_id)
	config.save_encrypted_pass("user://Preferences.agent", OS.get_unique_id())


## Clear stored tokens
func disconnect_account() -> void:
	access_token = ""
	refresh_token = ""
	expires_at = 0
	account_id = ""
	save_tokens()
	auth_status_changed.emit(false)


## Start the OAuth PKCE flow: generate PKCE, open browser, listen for callback
func start_auth_flow(scene_tree: SceneTree) -> void:
	if _auth_in_progress:
		return
	_auth_in_progress = true

	# Generate PKCE verifier and challenge
	var crypto := Crypto.new()
	var random_bytes := crypto.generate_random_bytes(32)
	_code_verifier = _base64url_encode(random_bytes)

	var hash_ctx := HashingContext.new()
	hash_ctx.start(HashingContext.HASH_SHA256)
	hash_ctx.update(_code_verifier.to_utf8_buffer())
	var challenge_hash := hash_ctx.finish()
	var code_challenge := _base64url_encode(challenge_hash)

	# Generate random state
	_state = _base64url_encode(crypto.generate_random_bytes(16))

	# Build authorization URL
	var params := {
		"response_type": "code",
		"client_id": CLIENT_ID,
		"redirect_uri": REDIRECT_URI,
		"scope": SCOPE,
		"code_challenge": code_challenge,
		"code_challenge_method": "S256",
		"state": _state,
		"id_token_add_organizations": "true",
		"codex_cli_simplified_flow": "true",
		"originator": "codex_cli_rs",
	}
	var query_parts := PackedStringArray()
	for key in params:
		query_parts.append("%s=%s" % [key, params[key].uri_encode()])
	var auth_url := "%s?%s" % [AUTHORIZE_URL, "&".join(query_parts)]

	# Start TCP server for callback
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(CALLBACK_PORT)
	if err != OK:
		print("[ChatGPTAuth] Could not bind to port %d, error: %s" % [CALLBACK_PORT, err])
		_auth_in_progress = false
		auth_completed.emit(false, "Could not bind to port %d. Close any other app using that port and try again." % CALLBACK_PORT)
		return

	# Open browser
	OS.shell_open(auth_url)
	print("[ChatGPTAuth] Opened browser for OAuth login")

	# Poll for callback in background
	_poll_for_callback(scene_tree)


## Poll the TCP server for the OAuth callback
func _poll_for_callback(scene_tree: SceneTree) -> void:
	var timeout_secs := 300.0  # 5 minute timeout
	var elapsed := 0.0

	while elapsed < timeout_secs:
		await scene_tree.process_frame
		elapsed += scene_tree.root.get_process_delta_time()

		if _tcp_server == null:
			break

		if not _tcp_server.is_connection_available():
			continue

		var connection := _tcp_server.take_connection()
		if connection == null:
			continue

		# Wait for data
		var data := ""
		var read_timeout := 0.0
		while read_timeout < 5.0:
			if connection.get_available_bytes() > 0:
				data += connection.get_utf8_string(connection.get_available_bytes())
				if "\r\n\r\n" in data:
					break
			await scene_tree.process_frame
			read_timeout += scene_tree.root.get_process_delta_time()

		# Parse the HTTP request to extract code and state
		var code := ""
		var state := ""
		var first_line := data.split("\n")[0] if not data.is_empty() else ""
		# GET /auth/callback?code=XXX&state=YYY HTTP/1.1
		if "?" in first_line:
			var query_string: String = first_line.split("?")[1].split(" ")[0]
			for param in query_string.split("&"):
				var kv := param.split("=", true, 2)
				if kv.size() == 2:
					if kv[0] == "code":
						code = kv[1].uri_decode()
					elif kv[0] == "state":
						state = kv[1].uri_decode()

		# Send response HTML
		var html := "<html><body><h1>Authentication Successful</h1><p>You can close this tab and return to Minerva.</p></body></html>"
		var response := "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [html.length(), html]
		connection.put_data(response.to_utf8_buffer())
		# Give the browser a moment to receive the response
		await scene_tree.create_timer(0.2).timeout
		connection.disconnect_from_host()

		# Cleanup server
		_tcp_server.stop()
		_tcp_server = null

		# Validate state
		if state != _state:
			_auth_in_progress = false
			auth_completed.emit(false, "OAuth state mismatch. Please try again.")
			return

		if code.is_empty():
			_auth_in_progress = false
			auth_completed.emit(false, "No authorization code received.")
			return

		# Exchange code for tokens
		await _exchange_code(code, scene_tree)
		return

	# Timeout
	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null
	_auth_in_progress = false
	auth_completed.emit(false, "Authentication timed out. Please try again.")


## Exchange authorization code for tokens
func _exchange_code(code: String, scene_tree: SceneTree) -> void:
	var http := HTTPRequest.new()
	scene_tree.root.add_child(http)

	var body := "grant_type=authorization_code&client_id=%s&code=%s&code_verifier=%s&redirect_uri=%s" % [
		CLIENT_ID.uri_encode(),
		code.uri_encode(),
		_code_verifier.uri_encode(),
		REDIRECT_URI.uri_encode(),
	]

	var error := http.request(
		TOKEN_URL,
		["Content-Type: application/x-www-form-urlencoded"],
		HTTPClient.METHOD_POST,
		body,
	)

	if error != OK:
		http.queue_free()
		_auth_in_progress = false
		auth_completed.emit(false, "Failed to send token exchange request.")
		return

	var result: Array = await http.request_completed
	http.queue_free()

	var response_code: int = result[1]
	var response_body: PackedByteArray = result[3]

	if response_code < 200 or response_code > 299:
		_auth_in_progress = false
		var err_text := response_body.get_string_from_utf8()
		print("[ChatGPTAuth] Token exchange failed: %d %s" % [response_code, err_text])
		auth_completed.emit(false, "Token exchange failed (HTTP %d)." % response_code)
		return

	var json = JSON.parse_string(response_body.get_string_from_utf8())
	if json == null or not json is Dictionary:
		_auth_in_progress = false
		auth_completed.emit(false, "Invalid token response.")
		return

	var token_data: Dictionary = json
	access_token = token_data.get("access_token", "")
	refresh_token = token_data.get("refresh_token", "")
	var expires_in: int = token_data.get("expires_in", 0)
	expires_at = int(Time.get_unix_time_from_system() * 1000) + expires_in * 1000

	if access_token.is_empty() or refresh_token.is_empty():
		_auth_in_progress = false
		auth_completed.emit(false, "Token response missing required fields.")
		return

	# Decode JWT to extract account ID
	account_id = _extract_account_id(access_token)
	if account_id.is_empty():
		_auth_in_progress = false
		auth_completed.emit(false, "Authentication succeeded but could not extract account ID from token. The token format may have changed.")
		return

	save_tokens()
	_auth_in_progress = false
	auth_status_changed.emit(true)
	auth_completed.emit(true, "")
	print("[ChatGPTAuth] Authentication successful, account_id: %s" % account_id)


## Refresh the access token if it's about to expire (within 5 minutes)
func ensure_valid_token(scene_tree: SceneTree) -> bool:
	if access_token.is_empty():
		return false

	var now_ms := int(Time.get_unix_time_from_system() * 1000)
	var five_min_ms := 5 * 60 * 1000

	if now_ms < (expires_at - five_min_ms):
		return true  # Token is still valid

	if refresh_token.is_empty():
		return false

	# Refresh the token
	var http := HTTPRequest.new()
	scene_tree.root.add_child(http)

	var body := "grant_type=refresh_token&refresh_token=%s&client_id=%s" % [
		refresh_token.uri_encode(),
		CLIENT_ID.uri_encode(),
	]

	var error := http.request(
		TOKEN_URL,
		["Content-Type: application/x-www-form-urlencoded"],
		HTTPClient.METHOD_POST,
		body,
	)

	if error != OK:
		http.queue_free()
		return false

	var result: Array = await http.request_completed
	http.queue_free()

	var response_code: int = result[1]
	var response_body: PackedByteArray = result[3]

	if response_code < 200 or response_code > 299:
		print("[ChatGPTAuth] Token refresh failed: HTTP %d" % response_code)
		return false

	var json = JSON.parse_string(response_body.get_string_from_utf8())
	if json == null or not json is Dictionary:
		return false

	var token_data: Dictionary = json
	access_token = token_data.get("access_token", "")
	refresh_token = token_data.get("refresh_token", refresh_token)
	var expires_in: int = token_data.get("expires_in", 0)
	expires_at = int(Time.get_unix_time_from_system() * 1000) + expires_in * 1000

	if access_token.is_empty():
		return false

	# Re-extract account ID from new token
	var new_account_id := _extract_account_id(access_token)
	if not new_account_id.is_empty():
		account_id = new_account_id

	save_tokens()
	print("[ChatGPTAuth] Token refreshed successfully")
	return true


## Extract chatgpt_account_id from JWT access token
func _extract_account_id(token: String) -> String:
	var parts := token.split(".")
	if parts.size() < 2:
		return ""

	# Base64url decode the payload
	var payload_b64 := parts[1]
	# Add padding if needed
	var remainder := payload_b64.length() % 4
	if remainder > 0:
		payload_b64 += "=".repeat(4 - remainder)
	# Replace URL-safe chars
	payload_b64 = payload_b64.replace("-", "+").replace("_", "/")

	var decoded := Marshalls.base64_to_raw(payload_b64)
	if decoded.is_empty():
		return ""

	var json_str := decoded.get_string_from_utf8()
	var payload = JSON.parse_string(json_str)
	if payload == null or not payload is Dictionary:
		return ""

	# Account ID is at claim path "https://api.openai.com/auth"
	var auth_claim = payload.get(JWT_CLAIM_PATH, {})
	if auth_claim is Dictionary:
		# Try various possible field names
		for field in ["chatgpt_account_id", "account_id", "organization_id"]:
			var val = auth_claim.get(field, "")
			if val is String and not val.is_empty():
				return val
		# If there's an organizations array, use the first one
		var orgs = auth_claim.get("organizations", [])
		if orgs is Array and not orgs.is_empty():
			var first_org = orgs[0]
			if first_org is Dictionary:
				return first_org.get("id", "")

	return ""


## Base64url encode (no padding, URL-safe)
func _base64url_encode(data: PackedByteArray) -> String:
	var b64 := Marshalls.raw_to_base64(data)
	# Make URL-safe: replace + with -, / with _, remove padding =
	b64 = b64.replace("+", "-").replace("/", "_").rstrip("=")
	return b64
