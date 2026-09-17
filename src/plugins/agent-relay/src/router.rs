// router.rs — async stdio router for agent-relay.
//
// Architecture:
//
//   ┌──────────────┐        ┌──────────────────────┐
//   │  stdin       │        │  reader thread        │
//   │  (one line   ├───────►│  reads lines, routes:│
//   │   at a time) │        │  • capability replies │
//   └──────────────┘        │    → pending_map      │
//                           │  • tool requests      │
//                           │    → tool_tx channel  │
//                           └──────────────────────┘
//
//   ┌──────────────┐
//   │  stdout      │   ◄── Mutex<StdoutWriter> — all threads share one writer
//   │  (JSON-RPC   │       so tool responses, capability requests, and events
//   │   lines out) │       never interleave within a line.
//   └──────────────┘
//
// Pending-map: when the watch thread (or any background thread) wants to make a
// capability request, it:
//   1. Allocates a unique id string.
//   2. Inserts id → oneshot-sender into PENDING_MAP.
//   3. Writes the minerva/capability JSON-RPC request via the stdout writer.
//   4. Waits (blocks) on the oneshot-receiver.
//
// The reader thread, on seeing a reply (message has an "id" and no "method"),
// looks up the id in PENDING_MAP and sends the value on the channel.
//
// Tool requests (messages with "method": "tools/call" etc.) are forwarded to the
// main dispatch loop via a crossbeam channel.
//
// NOTE: id floats — Godot serialises every JSON number as float, so "1" echoes
// back as "1.0". We normalise on String: send "cap-1" (string id), read back
// as string — this avoids the float/int ambiguity entirely.

use std::collections::HashMap;
use std::io::{self, BufRead, BufWriter, Write};
use std::sync::{Arc, Mutex};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::thread;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

// ---------------------------------------------------------------------------
// Shared stdout writer
// ---------------------------------------------------------------------------

/// Thread-safe wrapper around a locked stdout BufWriter.
/// All writes go through this so that JSON-RPC lines never interleave.
pub struct StdoutWriter {
    inner: Mutex<BufWriter<io::Stdout>>,
}

impl StdoutWriter {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(BufWriter::new(io::stdout())),
        })
    }

    /// Write one serialisable value as a JSON line followed by a newline and flush.
    pub fn write_line(&self, v: &impl Serialize) {
        let s = match serde_json::to_string(v) {
            Ok(s) => s,
            Err(e) => {
                log::error!("StdoutWriter: serialize: {e}");
                return;
            }
        };
        let mut guard = self.inner.lock().unwrap();
        if let Err(e) = writeln!(guard, "{}", s) {
            log::error!("StdoutWriter: write: {e}");
        }
        let _ = guard.flush();
    }
}

// ---------------------------------------------------------------------------
// Pending-map for capability correlation
// ---------------------------------------------------------------------------

/// Maps capability-request id → oneshot sender.
/// The reader thread uses this to route replies back to waiting callers.
type PendingMap = Arc<Mutex<HashMap<String, mpsc::SyncSender<Value>>>>;

fn new_pending_map() -> PendingMap {
    Arc::new(Mutex::new(HashMap::new()))
}

// ---------------------------------------------------------------------------
// Inbound message classification
// ---------------------------------------------------------------------------

#[derive(Deserialize, Debug)]
pub struct InboundMsg {
    #[serde(default)]
    #[allow(dead_code)]
    pub jsonrpc: String,
    #[serde(default)]
    pub id: Value,
    #[serde(default)]
    pub method: String,
    #[serde(default)]
    pub params: Value,
    // error field — only on capability replies with errors
    pub error: Option<Value>,
    // result field — on capability replies
    pub result: Option<Value>,
}

/// A tool request extracted from the inbound stream.
pub struct ToolRequest {
    pub id: Value,
    pub method: String,
    pub params: Value,
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

pub struct Router {
    pub stdout: Arc<StdoutWriter>,
    // NOTE: tool_rx is NOT stored here because Receiver<T> is not Sync,
    // which would prevent Arc<Router> from being sent across threads.
    // The receiver is returned separately from spawn() and kept by the
    // main thread's dispatch loop.
    pending: PendingMap,
    next_cap_id: Mutex<u64>,
}

impl Router {
    /// Spawn the reader thread and return:
    /// - `Arc<Router>` — shared handle for capability calls and event emission.
    /// - `Receiver<ToolRequest>` — main thread's end of the tool-request channel.
    pub fn spawn() -> (Arc<Self>, Receiver<ToolRequest>) {
        let stdout = StdoutWriter::new();
        let pending: PendingMap = new_pending_map();
        // Buffered so that tool requests don't block the reader thread.
        let (tool_tx, tool_rx) = mpsc::sync_channel::<ToolRequest>(64);

        let router = Arc::new(Router {
            stdout: stdout.clone(),
            pending: pending.clone(),
            next_cap_id: Mutex::new(0),
        });

        // Spawn the reader thread. It owns stdin for the process lifetime.
        {
            let pending = pending.clone();
            thread::Builder::new()
                .name("stdin-reader".into())
                .spawn(move || {
                    reader_thread(pending, tool_tx);
                })
                .expect("spawn stdin-reader thread");
        }

        (router, tool_rx)
    }

    /// Make a capability request over the shared stdout and block until the reply
    /// arrives on the reader thread's routing channel.
    ///
    /// Thread-safe: can be called from ANY thread concurrently (each call gets
    /// its own unique id and its own oneshot channel).
    pub fn call_capability(&self, capability: &str, args: Value) -> Result<Value, String> {
        let id_str = {
            let mut n = self.next_cap_id.lock().unwrap();
            *n += 1;
            format!("cap-{}", *n)
        };

        // Register before writing (avoid TOCTOU where reader gets reply before
        // we have the receiver).
        let (tx, rx) = mpsc::sync_channel::<Value>(1);
        {
            let mut map = self.pending.lock().unwrap();
            map.insert(id_str.clone(), tx);
        }

        // Write the request.
        let req = json!({
            "jsonrpc": "2.0",
            "id": id_str,
            "method": "minerva/capability",
            "params": {
                "capability": capability,
                "args": args,
            }
        });
        self.stdout.write_line(&req);
        log::debug!("cap→ id={id_str} {capability}");

        // Block until the reader thread routes the reply.
        match rx.recv() {
            Ok(reply) => {
                // Check for error field (capability error from host).
                if let Some(err) = reply.get("error") {
                    return Err(format!("capability error: {err}"));
                }
                let result = reply.get("result").cloned().unwrap_or(Value::Null);
                // The CapabilityBroker wraps every reply in a
                // {success, result|error_message} envelope. Unwrap it so
                // callers see the capability payload directly. (Replies that
                // are already flat — no "success" key — pass through, which
                // keeps test stubs and any future raw paths working.)
                match result.get("success").and_then(|v| v.as_bool()) {
                    Some(true) => {
                        Ok(result.get("result").cloned().unwrap_or(result))
                    }
                    Some(false) => Err(format!(
                        "capability denied: {}",
                        result
                            .get("error_message")
                            .or_else(|| result.get("error_code"))
                            .map(|v| v.to_string())
                            .unwrap_or_else(|| result.to_string())
                    )),
                    None => Ok(result),
                }
            }
            Err(_) => Err(format!("capability channel closed waiting for {capability}")),
        }
    }

    /// Emit a minerva/plugin_event notification (no id, no response expected).
    pub fn emit_event(&self, event: &str, payload: Value) {
        let notif = json!({
            "jsonrpc": "2.0",
            "method": "minerva/plugin_event",
            "params": {
                "event": event,
                "payload": payload,
            }
        });
        self.stdout.write_line(&notif);
        log::debug!("event→ {event}");
    }
}

// ---------------------------------------------------------------------------
// Reader thread
// ---------------------------------------------------------------------------

fn reader_thread(
    pending: PendingMap,
    tool_tx: SyncSender<ToolRequest>,
) {
    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();

    while let Some(line_result) = lines.next() {
        let line = match line_result {
            Ok(l) => l,
            Err(e) => {
                log::error!("stdin-reader: read error: {e}");
                break;
            }
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let msg: InboundMsg = match serde_json::from_str(trimmed) {
            Ok(m) => m,
            Err(e) => {
                log::warn!("stdin-reader: malformed JSON: {e} — {trimmed}");
                continue;
            }
        };

        // Is this a capability reply? Replies have an id and NO method (or
        // method is empty). Tool requests have a non-empty method.
        if msg.method.is_empty() {
            // This is a reply (or an error reply with an id).
            let id_str = value_to_id_str(&msg.id);
            if let Some(id_str) = id_str {
                let sender = {
                    let mut map = pending.lock().unwrap();
                    map.remove(&id_str)
                };
                if let Some(tx) = sender {
                    // Build reply value (preserve error if any).
                    let reply = if let Some(err) = &msg.error {
                        json!({ "error": err })
                    } else {
                        json!({ "result": msg.result.unwrap_or(Value::Null) })
                    };
                    let _ = tx.send(reply);
                    log::debug!("stdin-reader: routed reply id={id_str}");
                } else {
                    log::warn!("stdin-reader: no pending entry for id={id_str}");
                }
            } else {
                log::debug!("stdin-reader: reply with null/unknown id shape, ignoring");
            }
            continue;
        }

        // It's an inbound request or notification (has a method).
        // Notifications (no id) are currently ignored; forward requests.
        match msg.method.as_str() {
            "notifications/initialized" => {
                // Standard MCP notification — no response needed.
                log::debug!("stdin-reader: notifications/initialized");
            }
            _ => {
                // Forward to the main dispatch loop.
                let req = ToolRequest {
                    id: msg.id,
                    method: msg.method,
                    params: msg.params,
                };
                if let Err(e) = tool_tx.send(req) {
                    log::error!("stdin-reader: tool_tx send error: {e} — exiting");
                    break;
                }
            }
        }
    }

    log::info!("stdin-reader: stdin closed, exiting");
    // Drop tool_tx — main loop will see Disconnected and exit.
}

/// Convert a serde_json::Value id to a String for pending-map lookup.
/// Handles:
///   String "cap-5"  → Some("cap-5")
///   Number 5.0      → Some("5") — for future integer-id support
///   Null            → None
fn value_to_id_str(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => {
            // Godot echoes integer ids as floats; normalise.
            if let Some(f) = n.as_f64() {
                Some(format!("{}", f as i64))
            } else {
                None
            }
        }
        _ => None,
    }
}
