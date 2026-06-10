// agent-relay-plugin — Phase B MCP server for Minerva's agent-relay plugin.
//
// Provides tools for watching CLI agent terminals, cleaning TUI chrome from
// output, and distilling agent turns. See manifest.json for the full tool
// surface and DCR 019eafbdcfb3 for the overall design.
//
// ## Architecture (B3 redesign)
//
// The B1/B2 synchronous model (main loop = stdin reader = capability caller)
// is replaced in B3 with an async router so that background watch threads can
// make host.terminal.wait capability calls concurrently with the main loop
// handling tool calls.
//
// Outer protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.
// Logging goes to stderr; stdout carries only JSON-RPC traffic.
//
// Thread layout:
//   stdin-reader thread  — owns stdin; routes replies to pending_map channels,
//                          tool requests to tool_rx channel.
//   main thread          — receives tool requests from tool_rx, dispatches,
//                          writes responses via StdoutWriter.
//   watch-<tid> threads  — one per active watch; call capability via Router
//                          (which uses pending_map); emit events via Router.
//
// All writes to stdout go through Arc<StdoutWriter> (Mutex<BufWriter<Stdout>>)
// to avoid line interleaving.

mod chrome_filter;
mod detector;
mod filter_rules;
mod profiles;
mod router;
mod watcher;

use std::sync::Arc;

use serde::Serialize;
use serde_json::{json, Value};

use filter_rules::{FilterRule, FilterRuleSet, RuleAction};
use router::Router;
use watcher::NotifyMode;

// ---------------------------------------------------------------------------
// Global worker state
// ---------------------------------------------------------------------------

use std::sync::Mutex;

/// Session-scoped named filter rules, shared across all tool handlers.
static FILTER_RULES: Mutex<Option<FilterRuleSet>> = Mutex::new(None);

fn init_filter_rules() {
    let mut guard = FILTER_RULES.lock().unwrap();
    *guard = Some(FilterRuleSet::new());
}

fn with_filter_rules<R>(f: impl FnOnce(&mut FilterRuleSet) -> R) -> R {
    let mut guard = FILTER_RULES.lock().unwrap();
    f(guard.as_mut().expect("filter rules not initialised"))
}

const PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "agent-relay";
const SERVER_VERSION: &str = "0.1.0";

// ---------------------------------------------------------------------------
// JSON-RPC envelope types (used for final response serialisation)
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct RpcResponse {
    jsonrpc: String,
    id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<RpcError>,
}

#[derive(Serialize)]
struct RpcError {
    code: i64,
    message: String,
}

fn ok_response(id: Value, result: Value) -> RpcResponse {
    RpcResponse { jsonrpc: "2.0".into(), id, result: Some(result), error: None }
}

fn err_response(id: Value, code: i64, message: String) -> RpcResponse {
    RpcResponse { jsonrpc: "2.0".into(), id, result: None, error: Some(RpcError { code, message }) }
}

// ---------------------------------------------------------------------------
// Tool content helpers
// ---------------------------------------------------------------------------

fn tool_ok(payload: Value) -> Value {
    let text = serde_json::to_string(&payload).unwrap_or_else(|_| r#"{"ok":false}"#.into());
    json!({ "content": [{"type": "text", "text": text}] })
}

fn tool_err(message: &str) -> Value {
    let text = serde_json::to_string(&json!({"error": message}))
        .unwrap_or_else(|_| r#"{"error":"serialisation failed"}"#.into());
    json!({ "isError": true, "content": [{"type": "text", "text": text}] })
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

/// B3 IMPLEMENTED: watch_start — start watching a terminal for turn completion.
fn handle_watch_start(params: &Value, id: Value, router: &Arc<Router>) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let terminal_id = args.get("terminal_id").and_then(|v| v.as_str()).unwrap_or("");
    if terminal_id.is_empty() {
        return ok_response(id, tool_err("terminal_id is required"));
    }

    let profile_id = args.get("profile")
        .or_else(|| args.get("profile_id"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    let notify_mode_str = args.get("notify_mode").and_then(|v| v.as_str()).unwrap_or("armed");
    let notify_mode = NotifyMode::from_str(notify_mode_str);

    match watcher::watch_start(terminal_id.to_string(), profile_id, notify_mode, router.clone()) {
        Ok(()) => ok_response(id, tool_ok(json!({
            "ok": true,
            "terminal_id": terminal_id,
            "message": "watch session started"
        }))),
        Err(e) => ok_response(id, tool_err(&e)),
    }
}

/// B3 IMPLEMENTED: watch_stop — stop watching a terminal.
fn handle_watch_stop(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let terminal_id = args.get("terminal_id").and_then(|v| v.as_str()).unwrap_or("");
    if terminal_id.is_empty() {
        return ok_response(id, tool_err("terminal_id is required"));
    }

    let was_watching = watcher::watch_stop(terminal_id);
    ok_response(id, tool_ok(json!({
        "ok": true,
        "terminal_id": terminal_id,
        "was_watching": was_watching
    })))
}

/// B3 IMPLEMENTED: watch_status — report watch session state.
fn handle_watch_status(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let terminal_id = args.get("terminal_id").and_then(|v| v.as_str()).unwrap_or("");
    if terminal_id.is_empty() {
        return ok_response(id, tool_err("terminal_id is required"));
    }

    match watcher::watch_status(terminal_id) {
        Some(status) => ok_response(id, tool_ok(json!({
            "ok": true,
            "terminal_id": terminal_id,
            "status": status
        }))),
        None => ok_response(id, tool_ok(json!({
            "ok": true,
            "terminal_id": terminal_id,
            "status": null,
            "watching": false
        }))),
    }
}

/// B3 IMPLEMENTED: send — write text to terminal and arm one-shot watch.
/// Full send implementation: writes via host.terminal.write + arms watch.
fn handle_send(params: &Value, id: Value, router: &Arc<Router>) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let terminal_id = args.get("terminal_id").and_then(|v| v.as_str()).unwrap_or("");
    let text = args.get("text").and_then(|v| v.as_str()).unwrap_or("");
    let do_arm = args.get("arm").and_then(|v| v.as_bool()).unwrap_or(true);

    if terminal_id.is_empty() {
        return ok_response(id, tool_err("terminal_id is required"));
    }
    if text.is_empty() {
        return ok_response(id, tool_err("text is required"));
    }

    // Write to the terminal via host capability.
    let write_result = router.call_capability("host.terminal.write", json!({
        "terminal_id": terminal_id,
        "text": text,
    }));

    match write_result {
        Err(e) => ok_response(id, tool_err(&format!("terminal write failed: {e}"))),
        Ok(_) => {
            let armed = if do_arm {
                watcher::arm(terminal_id)
            } else {
                false
            };
            ok_response(id, tool_ok(json!({
                "ok": true,
                "terminal_id": terminal_id,
                "written": text,
                "armed": armed
            })))
        }
    }
}

/// B3 IMPLEMENTED: read_clean — reads from live terminal (or raw_text) and
/// applies the full chrome filter pipeline.
fn handle_read_clean(params: &Value, id: Value, router: &Arc<Router>) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);

    let raw_text = args.get("raw_text").and_then(|v| v.as_str());
    let terminal_id = args.get("terminal_id").and_then(|v| v.as_str()).unwrap_or("");
    let do_redact = args.get("redact").and_then(|v| v.as_bool()).unwrap_or(true);

    let raw = match raw_text {
        Some(t) => t.to_string(),
        None => {
            if terminal_id.is_empty() {
                return ok_response(id, tool_err("terminal_id or raw_text is required"));
            }
            // Read from live terminal via host capability.
            match router.call_capability("host.terminal.read", json!({
                "terminal_id": terminal_id,
            })) {
                Err(e) => return ok_response(id, tool_err(&format!("terminal read failed: {e}"))),
                Ok(result) => {
                    result.get("content")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string()
                }
            }
        }
    };

    // Pass 1: built-in chrome filter.
    let mut cleaned = chrome_filter::filter(&raw);

    // Pass 2: named filter rules.
    cleaned = with_filter_rules(|rs| rs.apply(&cleaned));

    // Pass 3: inline extra_patterns.
    if let Some(patterns) = args.get("extra_patterns").and_then(|v| v.as_array()) {
        for pattern_val in patterns {
            if let Some(pat) = pattern_val.as_str() {
                match regex::Regex::new(pat) {
                    Ok(re) => {
                        let ends_nl = cleaned.ends_with('\n');
                        let lines: Vec<&str> = cleaned.lines().filter(|l| !re.is_match(l)).collect();
                        cleaned = lines.join("\n");
                        if ends_nl { cleaned.push('\n'); }
                    }
                    Err(e) => {
                        return ok_response(id, tool_err(
                            &format!("invalid extra_pattern '{}': {}", pat, e)
                        ));
                    }
                }
            }
        }
    }

    // Pass 4: redaction.
    if do_redact {
        cleaned = chrome_filter::redact(&cleaned);
    }

    // Pass 5: honest truncation.
    let trunc = chrome_filter::truncate(&cleaned, chrome_filter::MAX_OUTPUT_CHARS);

    ok_response(id, tool_ok(json!({
        "ok": true,
        "cleaned": trunc.text,
        "truncated": trunc.truncated,
        "omitted_chars": trunc.omitted_chars
    })))
}

/// B1 STUB: read_turn — reads and distils a turn via host.providers.chat.
/// Full implementation in B4.
fn handle_read_turn(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let terminal_id = args.get("terminal_id").and_then(|v| v.as_str()).unwrap_or("");
    if terminal_id.is_empty() {
        return ok_response(id, tool_err("terminal_id is required"));
    }
    ok_response(id, tool_ok(json!({
        "success": false,
        "error": "not_implemented",
        "note": "read_turn is a B4 work item"
    })))
}

/// B2 IMPLEMENTED: filter_set — installs or replaces a named filter rule.
fn handle_filter_set(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let name = args.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let pattern = args.get("pattern").and_then(|v| v.as_str()).unwrap_or("");
    let action_str = args.get("action").and_then(|v| v.as_str()).unwrap_or("");
    let replacement = args.get("replacement").and_then(|v| v.as_str()).unwrap_or("");

    if name.is_empty() {
        return ok_response(id, tool_err("name is required"));
    }
    if pattern.is_empty() {
        return ok_response(id, tool_err("pattern is required"));
    }

    let action = match action_str {
        "drop_line"  => RuleAction::DropLine,
        "replace"    => RuleAction::Replace,
        "strip_match" => RuleAction::StripMatch,
        "" => return ok_response(id, tool_err("action is required")),
        other => return ok_response(id, tool_err(
            &format!("unknown action '{}'; valid values: drop_line, replace, strip_match", other)
        )),
    };

    match FilterRule::new(name, pattern, action, replacement) {
        Ok(rule) => {
            let updated = with_filter_rules(|rs| rs.set(rule));
            ok_response(id, tool_ok(json!({ "ok": true, "updated": updated, "name": name })))
        }
        Err(e) => ok_response(id, tool_err(&e)),
    }
}

/// B2 IMPLEMENTED: filter_list — lists all installed filter rules.
fn handle_filter_list(_params: &Value, id: Value) -> RpcResponse {
    let rules_json = with_filter_rules(|rs| {
        rs.iter().map(|r| {
            let v = r.view();
            json!({ "name": v.name, "pattern": v.pattern, "action": v.action, "replacement": v.replacement })
        }).collect::<Vec<_>>()
    });
    ok_response(id, tool_ok(json!({ "ok": true, "rules": rules_json })))
}

/// B2 IMPLEMENTED: filter_delete — removes a named filter rule.
fn handle_filter_delete(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let name = args.get("name").and_then(|v| v.as_str()).unwrap_or("");
    if name.is_empty() {
        return ok_response(id, tool_err("name is required"));
    }
    let deleted = with_filter_rules(|rs| rs.delete(name));
    ok_response(id, tool_ok(json!({ "ok": true, "deleted": deleted, "name": name })))
}

/// B3 IMPLEMENTED: profile_get — retrieves a CLI agent detection profile.
fn handle_profile_get(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let profile_id = args.get("id").and_then(|v| v.as_str()).unwrap_or("");
    if profile_id.is_empty() {
        return ok_response(id, tool_err("id is required"));
    }
    match profiles::profile_get(profile_id) {
        Some(p) => {
            match serde_json::to_value(&p) {
                Ok(v) => ok_response(id, tool_ok(json!({ "ok": true, "profile": v }))),
                Err(e) => ok_response(id, tool_err(&format!("serialization error: {e}"))),
            }
        }
        None => ok_response(id, tool_err(&format!("profile '{}' not found", profile_id))),
    }
}

/// B3 IMPLEMENTED: profile_set — creates or updates a CLI agent detection profile.
fn handle_profile_set(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let profile_id = args.get("id").and_then(|v| v.as_str()).unwrap_or("");
    if profile_id.is_empty() {
        return ok_response(id, tool_err("id is required"));
    }

    // Start from existing profile or create a new minimal one.
    let mut profile = profiles::profile_get(profile_id).unwrap_or_else(|| {
        profiles::Profile {
            id: profile_id.to_string(),
            display_name: profile_id.to_string(),
            detection: profiles::Detection {
                prompt_box_regex: String::new(),
                permission_dialog_regex: None,
                spinner_glyphs: vec![],
                alt_screen: false,
                bell_capable: false,
                settle_ms: 1_500,
                watch_timeout_ms: 600_000,
            },
        }
    });

    // Apply display_name override.
    if let Some(name) = args.get("display_name").and_then(|v| v.as_str()) {
        profile.display_name = name.to_string();
    }

    // Apply detection overrides from nested "detection" object.
    if let Some(det_obj) = args.get("detection") {
        if let Some(s) = det_obj.get("prompt_box_regex").and_then(|v| v.as_str()) {
            // Validate regex before storing.
            if let Err(e) = regex::Regex::new(s) {
                return ok_response(id, tool_err(&format!("invalid prompt_box_regex: {e}")));
            }
            profile.detection.prompt_box_regex = s.to_string();
        }
        if let Some(s) = det_obj.get("permission_dialog_regex").and_then(|v| v.as_str()) {
            if !s.is_empty() {
                if let Err(e) = regex::Regex::new(s) {
                    return ok_response(id, tool_err(&format!("invalid permission_dialog_regex: {e}")));
                }
                profile.detection.permission_dialog_regex = Some(s.to_string());
            } else {
                profile.detection.permission_dialog_regex = None;
            }
        }
        if let Some(arr) = det_obj.get("spinner_glyphs").and_then(|v| v.as_array()) {
            profile.detection.spinner_glyphs = arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect();
        }
        if let Some(b) = det_obj.get("alt_screen").and_then(|v| v.as_bool()) {
            profile.detection.alt_screen = b;
        }
        if let Some(b) = det_obj.get("bell_capable").and_then(|v| v.as_bool()) {
            profile.detection.bell_capable = b;
        }
        if let Some(n) = det_obj.get("settle_ms").and_then(|v| v.as_u64()) {
            profile.detection.settle_ms = n;
        }
        if let Some(n) = det_obj.get("watch_timeout_ms").and_then(|v| v.as_u64()) {
            profile.detection.watch_timeout_ms = n;
        }
    }

    profiles::profile_set(profile.clone());

    match serde_json::to_value(&profile) {
        Ok(v) => ok_response(id, tool_ok(json!({ "ok": true, "profile": v }))),
        Err(e) => ok_response(id, tool_err(&format!("serialization error: {e}"))),
    }
}

/// B3 IMPLEMENTED: profiles_list — returns all known CLI agent detection profiles.
fn handle_profiles_list(_params: &Value, id: Value) -> RpcResponse {
    let profiles = profiles::profiles_list();
    match serde_json::to_value(&profiles) {
        Ok(v) => ok_response(id, tool_ok(json!({
            "ok": true,
            "profiles": v
        }))),
        Err(e) => ok_response(id, tool_err(&format!("serialization error: {e}"))),
    }
}

// ---------------------------------------------------------------------------
// tools/list schema (mirrors manifest.json — keep in sync)
// ---------------------------------------------------------------------------

fn tools_list_schema() -> Value {
    json!({
        "tools": [
            {
                "name": "minerva_agent_relay_watch_start",
                "description": "Arm a watch session on an open terminal tab for a running CLI agent.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "terminal_id": {"type": "string", "description": "ID of the terminal to watch."},
                        "profile": {"type": "string", "description": "CLI agent profile (e.g. 'claude', 'codex', 'opencode')."},
                        "notify_mode": {"type": "string", "enum": ["armed", "all_turns", "none"],
                            "description": "armed = emit only when armed (default); all_turns = every detected turn; none = silent."}
                    },
                    "required": ["terminal_id"]
                }
            },
            {
                "name": "minerva_agent_relay_watch_stop",
                "description": "Disarm and tear down the watch session for a terminal.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "terminal_id": {"type": "string", "description": "ID of the terminal whose watch session to stop."}
                    },
                    "required": ["terminal_id"]
                }
            },
            {
                "name": "minerva_agent_relay_watch_status",
                "description": "Return the current state of a watch session (watching, armed, last_wake_cause, last_turn_at, detection_method).",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "terminal_id": {"type": "string", "description": "ID of the terminal to query."}
                    },
                    "required": ["terminal_id"]
                }
            },
            {
                "name": "minerva_agent_relay_send",
                "description": "Send text to a watched terminal via host.terminal.write and arm a one-shot wake (default arm=true).",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "terminal_id": {"type": "string"},
                        "text": {"type": "string", "description": "Text to send. Use \\r for Enter."},
                        "arm": {"type": "boolean", "description": "When true (default), arm the watch session for one-shot notification."}
                    },
                    "required": ["terminal_id", "text"]
                }
            },
            {
                "name": "minerva_agent_relay_read_clean",
                "description": "Read terminal output (live or raw_text) and apply the chrome filter pipeline.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "terminal_id": {"type": "string"},
                        "raw_text": {"type": "string"},
                        "extra_patterns": {"type": "array", "items": {"type": "string"}},
                        "redact": {"type": "boolean", "description": "Apply built-in redaction pass (default true)."}
                    }
                }
            },
            {
                "name": "minerva_agent_relay_read_turn",
                "description": "Read the latest agent turn and distil it via host.providers.chat (B4).",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "terminal_id": {"type": "string"},
                        "model_spec": {
                            "type": "object",
                            "properties": {
                                "kind": {"type": "string"},
                                "service_client_id": {"type": "string"},
                                "action_name": {"type": "string"}
                            }
                        }
                    },
                    "required": ["terminal_id"]
                }
            },
            {
                "name": "minerva_agent_relay_filter_set",
                "description": "Install or replace a named chrome-filter rule.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                        "pattern": {"type": "string"},
                        "action": {"type": "string", "enum": ["drop_line", "replace", "strip_match"]},
                        "replacement": {"type": "string"}
                    },
                    "required": ["name", "pattern", "action"]
                }
            },
            {
                "name": "minerva_agent_relay_filter_list",
                "description": "List all installed chrome-filter rules.",
                "inputSchema": {"type": "object", "properties": {}}
            },
            {
                "name": "minerva_agent_relay_filter_delete",
                "description": "Remove a named chrome-filter rule.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"name": {"type": "string"}},
                    "required": ["name"]
                }
            },
            {
                "name": "minerva_agent_relay_profile_get",
                "description": "Get the detection profile for a specific CLI agent.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"id": {"type": "string"}},
                    "required": ["id"]
                }
            },
            {
                "name": "minerva_agent_relay_profile_set",
                "description": "Create or update a CLI agent detection profile.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string"},
                        "display_name": {"type": "string"},
                        "detection": {
                            "type": "object",
                            "properties": {
                                "prompt_box_regex": {"type": "string"},
                                "permission_dialog_regex": {"type": "string"},
                                "spinner_glyphs": {"type": "array", "items": {"type": "string"}},
                                "alt_screen": {"type": "boolean"},
                                "bell_capable": {"type": "boolean"},
                                "settle_ms": {"type": "integer"},
                                "watch_timeout_ms": {"type": "integer"}
                            }
                        }
                    },
                    "required": ["id"]
                }
            },
            {
                "name": "minerva_agent_relay_profiles_list",
                "description": "List all known CLI agent detection profiles.",
                "inputSchema": {"type": "object", "properties": {}}
            }
        ]
    })
}

// ---------------------------------------------------------------------------
// main — spawn router, then dispatch tool requests from tool_rx
// ---------------------------------------------------------------------------

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .target(env_logger::Target::Stderr)
        .init();

    log::info!("{SERVER_NAME} {SERVER_VERSION} starting");

    // Initialise global state.
    init_filter_rules();
    profiles::init_profiles();
    watcher::init_sessions();

    // Spawn the async router (stdin-reader thread + shared stdout writer).
    // tool_rx stays on the main thread (Receiver is not Sync; can't put it in Arc).
    let (router, tool_rx) = Router::spawn();

    log::info!("{SERVER_NAME} router ready, waiting for tool requests");

    // Main dispatch loop — receive tool requests from the router's tool_rx channel.
    loop {
        let req = match tool_rx.recv() {
            Ok(r) => r,
            Err(_) => {
                log::info!("{SERVER_NAME}: tool_rx closed (stdin EOF), exiting");
                break;
            }
        };

        log::debug!("← {}", req.method);

        let resp = match req.method.as_str() {
            "initialize" => ok_response(req.id, json!({
                "protocolVersion": PROTOCOL_VERSION,
                "serverName": SERVER_NAME,
                "serverVersion": SERVER_VERSION,
                "capabilities": {"tools": {}},
            })),

            "tools/list" => ok_response(req.id, tools_list_schema()),

            "tools/call" => {
                let tool_name = req.params.get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");

                log::debug!("tool call: {tool_name}");

                match tool_name {
                    "minerva_agent_relay_watch_start" =>
                        handle_watch_start(&req.params, req.id, &router),
                    "minerva_agent_relay_watch_stop" =>
                        handle_watch_stop(&req.params, req.id),
                    "minerva_agent_relay_watch_status" =>
                        handle_watch_status(&req.params, req.id),
                    "minerva_agent_relay_send" =>
                        handle_send(&req.params, req.id, &router),
                    "minerva_agent_relay_read_clean" =>
                        handle_read_clean(&req.params, req.id, &router),
                    "minerva_agent_relay_read_turn" =>
                        handle_read_turn(&req.params, req.id),
                    "minerva_agent_relay_filter_set" =>
                        handle_filter_set(&req.params, req.id),
                    "minerva_agent_relay_filter_list" =>
                        handle_filter_list(&req.params, req.id),
                    "minerva_agent_relay_filter_delete" =>
                        handle_filter_delete(&req.params, req.id),
                    "minerva_agent_relay_profile_get" =>
                        handle_profile_get(&req.params, req.id),
                    "minerva_agent_relay_profile_set" =>
                        handle_profile_set(&req.params, req.id),
                    "minerva_agent_relay_profiles_list" =>
                        handle_profiles_list(&req.params, req.id),
                    other => {
                        log::warn!("unknown tool: {other}");
                        err_response(req.id, -32601, format!("unknown tool: {other}"))
                    }
                }
            }

            // Notifications and unknown methods — no response needed.
            other => {
                log::debug!("ignoring method: {other}");
                continue;
            }
        };

        router.stdout.write_line(&resp);
    }

    log::info!("{SERVER_NAME} exiting");
}
