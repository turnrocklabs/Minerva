// agent-relay-plugin — Phase B MCP server for Minerva's agent-relay plugin.
//
// Provides tools for watching CLI agent terminals, cleaning TUI chrome from
// output, and distilling agent turns. See manifest.json for the full tool
// surface and DCR 019eafbdcfb3 for the overall design.
//
// Outer protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.
// Logging goes to stderr; stdout carries only JSON-RPC traffic.
//
// Capability re-entrancy contract (from Minerva broker):
// While the plugin is handling a tools/call, Minerva will NOT send another
// tools/call. So when a handler writes a minerva/capability request to stdout,
// the next line on stdin is guaranteed to be either:
//   (a) the matching response (correlated by id), or
//   (b) stdin EOF.
// The synchronous read pattern below is safe under that guarantee.

mod chrome_filter;
mod filter_rules;
mod profiles;

use std::io::{self, BufRead, Write};
use std::sync::Mutex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use filter_rules::{FilterRule, FilterRuleSet, RuleAction};

// ---------------------------------------------------------------------------
// Global worker state
// ---------------------------------------------------------------------------

/// Session-scoped named filter rules, shared across all tool handlers.
/// Initialised once at startup; handlers lock briefly to read/write.
static FILTER_RULES: Mutex<Option<FilterRuleSet>> = Mutex::new(None);

/// Initialise the global filter rule set. Called once from main().
fn init_filter_rules() {
    let mut guard = FILTER_RULES.lock().unwrap();
    *guard = Some(FilterRuleSet::new());
}

/// Run `f` with a mutable reference to the global FilterRuleSet.
/// Panics if init_filter_rules() was not called first.
fn with_filter_rules<R>(f: impl FnOnce(&mut FilterRuleSet) -> R) -> R {
    let mut guard = FILTER_RULES.lock().unwrap();
    f(guard.as_mut().expect("filter rules not initialised"))
}

const PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "agent-relay";
const SERVER_VERSION: &str = "0.1.0";

// ---------------------------------------------------------------------------
// JSON-RPC envelope types
// ---------------------------------------------------------------------------

#[derive(Deserialize, Debug)]
struct RpcRequest {
    #[serde(default)]
    jsonrpc: String,
    #[serde(default)]
    id: Value,
    method: String,
    #[serde(default)]
    params: Value,
}

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

fn write_line(out: &mut impl Write, v: &impl Serialize) {
    let s = serde_json::to_string(v).unwrap_or_else(|e| {
        log::error!("serialize response: {e}");
        String::new()
    });
    if let Err(e) = writeln!(out, "{}", s) {
        log::error!("write response: {e}");
    }
    let _ = out.flush();
}

// ---------------------------------------------------------------------------
// Tool content helpers
// ---------------------------------------------------------------------------

/// Wrap a JSON value as a text content MCP tool result.
fn tool_ok(payload: Value) -> Value {
    let text = serde_json::to_string(&payload).unwrap_or_else(|_| r#"{"ok":false}"#.into());
    json!({ "content": [{"type": "text", "text": text}] })
}

/// Return an MCP isError tool result with a message string.
fn tool_err(message: &str) -> Value {
    let text = serde_json::to_string(&json!({"error": message}))
        .unwrap_or_else(|_| r#"{"error":"serialisation failed"}"#.into());
    json!({ "isError": true, "content": [{"type": "text", "text": text}] })
}

// ---------------------------------------------------------------------------
// Capability round-trip helper
// ---------------------------------------------------------------------------

/// request_capability sends a minerva/capability request to Minerva and reads
/// the matching response. Safe only within a tools/call handler (re-entrancy
/// contract above).
fn request_capability(
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
    capability: &str,
    args: Value,
) -> Result<Value, String> {
    *next_id += 1;
    let id = format!("cap-{}", next_id);

    let req = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "minerva/capability",
        "params": {
            "capability": capability,
            "args": args,
        }
    });
    write_line(out, &req);
    log::debug!("sent capability request id={id} capability={capability}");

    for line_result in lines.by_ref() {
        let line = line_result.map_err(|e| format!("stdin read error: {e}"))?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(e) => {
                log::warn!("non-JSON line while waiting for capability response: {e}");
                continue;
            }
        };
        let msg_id = msg.get("id").cloned().unwrap_or(Value::Null);
        if msg_id.as_str() != Some(&id) {
            log::warn!("unexpected message id {:?} while waiting for {} (skipped)", msg_id, id);
            continue;
        }
        if let Some(err) = msg.get("error") {
            return Err(format!("capability error: {err}"));
        }
        return Ok(msg.get("result").cloned().unwrap_or(Value::Null));
    }
    Err("stdin closed waiting for capability response".into())
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

/// B1 STUB: watch_start — arms turn detection on a terminal.
/// Full implementation in B2/B3.
fn handle_watch_start(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let terminal_id = args.get("terminal_id").and_then(|v| v.as_str()).unwrap_or("");
    if terminal_id.is_empty() {
        return ok_response(id, tool_err("terminal_id is required"));
    }
    ok_response(id, tool_ok(json!({
        "success": false,
        "error": "not_implemented",
        "note": "watch_start is a B2/B3 work item"
    })))
}

/// B1 STUB: watch_stop — disarms a watch session.
/// Full implementation in B2/B3.
fn handle_watch_stop(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let terminal_id = args.get("terminal_id").and_then(|v| v.as_str()).unwrap_or("");
    if terminal_id.is_empty() {
        return ok_response(id, tool_err("terminal_id is required"));
    }
    ok_response(id, tool_ok(json!({
        "success": false,
        "error": "not_implemented",
        "note": "watch_stop is a B2/B3 work item"
    })))
}

/// B1 STUB: watch_status — reports watch session state.
/// Full implementation in B2/B3.
fn handle_watch_status(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let terminal_id = args.get("terminal_id").and_then(|v| v.as_str()).unwrap_or("");
    if terminal_id.is_empty() {
        return ok_response(id, tool_err("terminal_id is required"));
    }
    ok_response(id, tool_ok(json!({
        "success": false,
        "error": "not_implemented",
        "note": "watch_status is a B2/B3 work item"
    })))
}

/// B1 STUB: send — writes to terminal and arms one-shot wake.
/// Full implementation in B2/B3.
fn handle_send(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let terminal_id = args.get("terminal_id").and_then(|v| v.as_str()).unwrap_or("");
    let text = args.get("text").and_then(|v| v.as_str()).unwrap_or("");
    if terminal_id.is_empty() {
        return ok_response(id, tool_err("terminal_id is required"));
    }
    if text.is_empty() {
        return ok_response(id, tool_err("text is required"));
    }
    ok_response(id, tool_ok(json!({
        "success": false,
        "error": "not_implemented",
        "note": "send is a B2/B3 work item"
    })))
}

/// B2 IMPLEMENTED: read_clean — applies the chrome filter pipeline:
///   1. Built-in chrome filter (box-drawing, blank collapse).
///   2. Named rule-layer (filter_set rules, drop_line / replace).
///   3. Inline extra_patterns (regex, drop_line only).
///   4. Redaction pass (on by default, opt-out via redact:false).
///   5. Honest truncation (tail-keep, MAX_OUTPUT_CHARS cap).
///
/// When raw_text is provided, filters it directly (no terminal read needed).
/// Terminal reads from live terminals remain B3 work; terminal_id alone
/// returns not_implemented pointing at B3.
fn handle_read_clean(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);

    let raw_text = args.get("raw_text").and_then(|v| v.as_str());
    let terminal_id = args.get("terminal_id").and_then(|v| v.as_str()).unwrap_or("");

    // redact defaults to true; caller can opt out with redact:false.
    let do_redact = args.get("redact").and_then(|v| v.as_bool()).unwrap_or(true);

    let raw = match raw_text {
        Some(t) => t.to_string(),
        None => {
            if terminal_id.is_empty() {
                return ok_response(id, tool_err("terminal_id or raw_text is required"));
            }
            // Terminal read from live terminal is B3 work.
            return ok_response(id, tool_ok(json!({
                "success": false,
                "error": "not_implemented",
                "note": "live terminal reads are implemented in B3; pass raw_text to use the chrome filter now"
            })));
        }
    };

    // Pass 1: built-in chrome filter (box-drawing, border columns, blank collapse).
    let mut cleaned = chrome_filter::filter(&raw);

    // Pass 2: apply named filter rules from global state.
    cleaned = with_filter_rules(|rs| rs.apply(&cleaned));

    // Pass 3: inline extra_patterns (regex drop_line).
    if let Some(patterns) = args.get("extra_patterns").and_then(|v| v.as_array()) {
        for pattern_val in patterns {
            if let Some(pat) = pattern_val.as_str() {
                match regex::Regex::new(pat) {
                    Ok(re) => {
                        let ends_nl = cleaned.ends_with('\n');
                        let lines: Vec<&str> = cleaned
                            .lines()
                            .filter(|line| !re.is_match(line))
                            .collect();
                        cleaned = lines.join("\n");
                        if ends_nl {
                            cleaned.push('\n');
                        }
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

    // Pass 4: redaction (default on).
    if do_redact {
        cleaned = chrome_filter::redact(&cleaned);
    }

    // Pass 5: honest truncation — keep TAIL, report omitted chars.
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
/// Validates the regex at set time; bad patterns return a clear error.
/// Actions: "drop_line", "replace" (or legacy alias "strip_match").
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
        "drop_line" => RuleAction::DropLine,
        "replace" => RuleAction::Replace,
        "strip_match" => RuleAction::StripMatch, // backwards-compat alias
        "" => return ok_response(id, tool_err("action is required")),
        other => return ok_response(id, tool_err(
            &format!("unknown action '{}'; valid values: drop_line, replace, strip_match", other)
        )),
    };

    match FilterRule::new(name, pattern, action, replacement) {
        Ok(rule) => {
            let updated = with_filter_rules(|rs| rs.set(rule));
            ok_response(id, tool_ok(json!({
                "ok": true,
                "updated": updated,
                "name": name
            })))
        }
        Err(e) => ok_response(id, tool_err(&e)),
    }
}

/// B2 IMPLEMENTED: filter_list — lists all installed filter rules.
fn handle_filter_list(_params: &Value, id: Value) -> RpcResponse {
    let rules_json = with_filter_rules(|rs| {
        rs.iter()
            .map(|r| {
                let v = r.view();
                json!({
                    "name": v.name,
                    "pattern": v.pattern,
                    "action": v.action,
                    "replacement": v.replacement
                })
            })
            .collect::<Vec<_>>()
    });
    ok_response(id, tool_ok(json!({
        "ok": true,
        "rules": rules_json
    })))
}

/// B2 IMPLEMENTED: filter_delete — removes a named filter rule.
fn handle_filter_delete(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let name = args.get("name").and_then(|v| v.as_str()).unwrap_or("");
    if name.is_empty() {
        return ok_response(id, tool_err("name is required"));
    }
    let deleted = with_filter_rules(|rs| rs.delete(name));
    ok_response(id, tool_ok(json!({
        "ok": true,
        "deleted": deleted,
        "name": name
    })))
}

/// B1 STUB: profile_get — retrieves a CLI agent detection profile.
/// Full implementation in B3.
fn handle_profile_get(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let profile_id = args.get("id").and_then(|v| v.as_str()).unwrap_or("");
    if profile_id.is_empty() {
        return ok_response(id, tool_err("id is required"));
    }
    ok_response(id, tool_ok(json!({
        "success": false,
        "error": "not_implemented",
        "note": "profile_get is a B3 work item"
    })))
}

/// B1 STUB: profile_set — creates or updates a CLI agent detection profile.
/// Full implementation in B3.
fn handle_profile_set(params: &Value, id: Value) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let profile_id = args.get("id").and_then(|v| v.as_str()).unwrap_or("");
    if profile_id.is_empty() {
        return ok_response(id, tool_err("id is required"));
    }
    ok_response(id, tool_ok(json!({
        "success": false,
        "error": "not_implemented",
        "note": "profile_set is a B3 work item"
    })))
}

/// B1 IMPLEMENTED: profiles_list — returns the built-in per-CLI detection profiles.
/// Returns all three CLIs (claude, codex, opencode) with calibration-pending values.
fn handle_profiles_list(_params: &Value, id: Value) -> RpcResponse {
    let profiles = profiles::builtin_profiles();
    match serde_json::to_value(&profiles) {
        Ok(v) => ok_response(id, tool_ok(json!({
            "ok": true,
            "profiles": v,
            "note": "Detection values are calibration-pending; will be refined in B3."
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
                        "notify_mode": {"type": "string", "enum": ["armed", "all_turns", "none"]}
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
                "description": "Return the current state of a watch session.",
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
                "description": "Send text to a watched terminal and arm a one-shot wake.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "terminal_id": {"type": "string"},
                        "text": {"type": "string", "description": "Text to send. Use \\r for Enter."},
                        "arm": {"type": "boolean"}
                    },
                    "required": ["terminal_id", "text"]
                }
            },
            {
                "name": "minerva_agent_relay_read_clean",
                "description": "Read terminal output and apply the chrome filter to strip TUI decorations.",
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
                "description": "Read the latest agent turn and distil it via host.providers.chat.",
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
                        "replacement": {"type": "string", "description": "Replacement string for replace/strip_match actions (default empty string)."}
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
                    "properties": {
                        "name": {"type": "string"}
                    },
                    "required": ["name"]
                }
            },
            {
                "name": "minerva_agent_relay_profile_get",
                "description": "Get the detection profile for a specific CLI agent.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string"}
                    },
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
                                "spinner_glyphs": {"type": "array", "items": {"type": "string"}},
                                "alt_screen": {"type": "boolean"},
                                "bell_capable": {"type": "boolean"}
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
// main — JSON-RPC dispatch loop
// ---------------------------------------------------------------------------

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .target(env_logger::Target::Stderr)
        .init();

    log::info!("{SERVER_NAME} {SERVER_VERSION} starting");

    init_filter_rules();

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    let mut lines = stdin.lock().lines();
    let mut next_id: u64 = 0;

    while let Some(line_result) = lines.next() {
        let line = match line_result {
            Ok(l) => l,
            Err(e) => {
                log::error!("stdin read: {e}");
                break;
            }
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let req: RpcRequest = match serde_json::from_str(trimmed) {
            Ok(r) => r,
            Err(e) => {
                log::warn!("malformed request: {e} — {trimmed}");
                continue;
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
                let tool_name = req.params
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");

                log::debug!("tool call: {tool_name}");

                match tool_name {
                    "minerva_agent_relay_watch_start" =>
                        handle_watch_start(&req.params, req.id),
                    "minerva_agent_relay_watch_stop" =>
                        handle_watch_stop(&req.params, req.id),
                    "minerva_agent_relay_watch_status" =>
                        handle_watch_status(&req.params, req.id),
                    "minerva_agent_relay_send" =>
                        handle_send(&req.params, req.id),
                    "minerva_agent_relay_read_clean" =>
                        handle_read_clean(&req.params, req.id),
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

            // Notifications and unknown methods — no response.
            other => {
                log::debug!("ignoring method: {other}");
                continue;
            }
        };

        write_line(&mut out, &resp);
    }

    log::info!("{SERVER_NAME} exiting");
}
