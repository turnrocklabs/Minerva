// common/mod.rs — a scriptable fake Minerva host for the plugin's integration
// tests.
//
// The plugin is spawned as its real binary with piped stdio; this module plays
// the host on the other end of the pipe: it answers `minerva/capability`
// requests from three closures the test supplies (what a screen read returns,
// what a windowed turn read returns, what a settle wait returns) and records
// every terminal write in order. Nothing is mocked inside the plugin.
//
// Each closure is handed a HostView — the counters and the write log as they
// stand — so a test can make the screen depend on what the plugin has done so
// far ("this screen until the second write", "a busy screen after it").

#![allow(dead_code)]

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{json, Value};

static COUNTER: AtomicU64 = AtomicU64::new(9000);

pub fn next_id() -> u64 {
    COUNTER.fetch_add(1, Ordering::SeqCst)
}

/// What the plugin has done to the terminal so far.
#[derive(Debug, Clone, Default)]
pub struct HostView {
    /// Every text the plugin wrote to a terminal, in order.
    pub writes: Vec<String>,
    /// The full arguments of every host.terminal.write, in order.
    pub write_args: Vec<Value>,
    /// Plain screen reads (no row range) — the send gate's reads.
    pub reads: usize,
    /// Windowed reads (start_row present) — read_turn's reads.
    pub turn_reads: usize,
    /// host.terminal.wait calls answered.
    pub waits: usize,
}

type ScreenFn = Box<dyn Fn(&HostView) -> (String, u64) + Send>;
type FailFn = Box<dyn Fn(&HostView) -> bool + Send>;
type TurnFn = Box<dyn Fn(&HostView) -> String + Send>;
type WaitFn = Box<dyn Fn(&HostView) -> Value + Send>;

pub struct FakeHost {
    child: Child,
    stdin: ChildStdin,
    out: BufReader<ChildStdout>,
    view: HostView,
    replies: HashMap<u64, Value>,
    pub events: Vec<Value>,
    /// Screen for a plain host.terminal.read: (content, total_scrollback_rows).
    pub screen: ScreenFn,
    /// When this says true, a plain screen read FAILS (the capability is
    /// refused) instead of answering — a terminal the host cannot read.
    pub screen_fails: FailFn,
    /// Content for a windowed host.terminal.read (read_turn).
    pub turn: TurnFn,
    /// Full host.terminal.wait result.
    pub wait: WaitFn,
}

impl FakeHost {
    /// Spawn the plugin with its own state file and complete the MCP handshake.
    pub fn start() -> Self {
        let bin = env!("CARGO_BIN_EXE_agent-relay-plugin");
        let state_file = std::env::temp_dir().join(format!(
            "agent-relay-gate-state-{}-{}.json",
            std::process::id(),
            next_id(),
        ));
        let mut child = Command::new(bin)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("AGENT_RELAY_STATE_FILE", &state_file)
            .spawn()
            .expect("spawn agent-relay-plugin");
        let stdin = child.stdin.take().expect("stdin");
        let out = BufReader::new(child.stdout.take().expect("stdout"));
        let mut host = FakeHost {
            child,
            stdin,
            out,
            view: HostView::default(),
            replies: HashMap::new(),
            events: Vec::new(),
            screen: Box::new(|_| (String::new(), 0)),
            screen_fails: Box::new(|_| false),
            turn: Box::new(|_| String::new()),
            wait: Box::new(|_| {
                json!({
                    "content": "", "timed_out": true,
                    "bell_rung": false, "shell_exited": false,
                })
            }),
        };
        host.handshake();
        host
    }

    fn handshake(&mut self) {
        let id = next_id();
        self.request(json!({
            "jsonrpc": "2.0", "id": id, "method": "initialize", "params": {}
        }));
        self.await_reply(id);
        self.raw_line("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    }

    pub fn view(&self) -> HostView {
        self.view.clone()
    }

    fn raw_line(&mut self, line: &str) {
        self.stdin.write_all(line.as_bytes()).expect("write");
        self.stdin.write_all(b"\n").expect("write newline");
        self.stdin.flush().expect("flush");
    }

    fn request(&mut self, req: Value) {
        let line = req.to_string();
        self.raw_line(&line);
    }

    /// Start a tool call without waiting for its reply. Returns its request id.
    pub fn call_tool(&mut self, name: &str, args: Value) -> u64 {
        let id = next_id();
        self.request(json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": {"name": name, "arguments": args},
        }));
        id
    }

    /// Run a tool call to completion and return its unwrapped payload.
    pub fn tool(&mut self, name: &str, args: Value) -> Value {
        let id = self.call_tool(name, args);
        let reply = self.await_reply(id);
        unwrap_tool(&reply)
    }

    /// Service messages until the reply to `id` arrives; returns it.
    pub fn await_reply(&mut self, id: u64) -> Value {
        for _ in 0..40_000 {
            if let Some(v) = self.replies.remove(&id) {
                return v;
            }
            self.step();
        }
        panic!("no reply to request {id} after 40000 messages");
    }

    /// True once the reply to `id` has arrived (without consuming it).
    pub fn has_reply(&self, id: u64) -> bool {
        self.replies.contains_key(&id)
    }

    /// Service messages while `cond` holds. Stops early once every id in
    /// `until_replied` has answered.
    pub fn pump_while(&mut self, until_replied: &[u64], mut cond: impl FnMut(&HostView) -> bool) {
        for _ in 0..40_000 {
            if !until_replied.is_empty() && until_replied.iter().all(|id| self.has_reply(*id)) {
                return;
            }
            if !cond(&self.view) {
                return;
            }
            self.step();
        }
        panic!("pump_while ran for 40000 messages without its condition clearing");
    }

    /// Read one message from the plugin: answer capabilities from the script,
    /// stash replies and events.
    fn step(&mut self) {
        let mut buf = String::new();
        let n = self.out.read_line(&mut buf).expect("read line");
        if n == 0 {
            panic!("plugin closed stdout");
        }
        let trimmed = buf.trim();
        if trimmed.is_empty() {
            return;
        }
        let Ok(msg): Result<Value, _> = serde_json::from_str(trimmed) else {
            return;
        };
        let method = msg.get("method").and_then(|v| v.as_str()).unwrap_or("");
        if method == "minerva/capability" {
            self.answer_capability(&msg);
            return;
        }
        if !method.is_empty() {
            self.events.push(msg);
            return;
        }
        if let Some(id) = msg.get("id").and_then(|v| v.as_u64()) {
            self.replies.insert(id, msg);
        }
    }

    fn answer_capability(&mut self, msg: &Value) {
        let cap = msg["params"]["capability"].as_str().unwrap_or("").to_string();
        let id = msg.get("id").cloned().unwrap_or(Value::Null);
        let args = msg["params"]["args"].clone();
        let result = match cap.as_str() {
            "host.terminal.write" => {
                let text = args.get("text").and_then(|v| v.as_str()).unwrap_or("");
                self.view.writes.push(text.to_string());
                self.view.write_args.push(args.clone());
                json!({"bytes_sent": text.len()})
            }
            "host.terminal.read" => {
                if args.get("start_row").is_some() {
                    self.view.turn_reads += 1;
                    let content = (self.turn)(&self.view);
                    json!({"content": content})
                } else {
                    self.view.reads += 1;
                    if (self.screen_fails)(&self.view) {
                        self.refuse(id, "terminal read failed");
                        return;
                    }
                    let (content, rows) = (self.screen)(&self.view);
                    json!({
                        "content": content,
                        "rows": 40,
                        "cols": 120,
                        "total_scrollback_rows": rows,
                    })
                }
            }
            "host.terminal.wait" => {
                self.view.waits += 1;
                (self.wait)(&self.view)
            }
            // terminal.list, chat-provider register/unregister, note hooks:
            // a generic success keeps the plugin thread moving.
            _ => json!({}),
        };
        let reply = json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {"success": true, "result": result},
        });
        let line = reply.to_string();
        self.raw_line(&line);
    }

    /// Answer a capability request with the host's refusal envelope.
    fn refuse(&mut self, id: Value, message: &str) {
        let reply = json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {"success": false, "error_message": message},
        });
        let line = reply.to_string();
        self.raw_line(&line);
    }

    /// Start a watch session and let its first settle wait land.
    pub fn watch_start(&mut self, terminal_id: &str, profile: &str) {
        self.tool(
            "minerva_agent_relay_watch_start",
            json!({
                "terminal_id": terminal_id,
                "profile": profile,
                "notify_mode": "armed",
            }),
        );
        let before = self.view.waits;
        self.pump_while(&[], |v| v.waits <= before);
    }
}

impl Drop for FakeHost {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Unwrap a tool result's inner JSON payload.
pub fn unwrap_tool(reply: &Value) -> Value {
    let result = reply
        .get("result")
        .unwrap_or_else(|| panic!("no result: {reply}"));
    let text = result["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("no content text: {reply}"));
    serde_json::from_str(text).unwrap_or_else(|e| panic!("content not JSON ({e}): {text}"))
}

/// A settled host.terminal.wait result carrying `screen`.
pub fn settled(screen: &str, rows: u64) -> Value {
    json!({
        "content": screen,
        "total_scrollback_rows": rows,
        "timed_out": false,
        "bell_rung": false,
        "shell_exited": false,
    })
}

/// A wait that timed out with nothing to look at (the quiet terminal).
pub fn quiet() -> Value {
    json!({
        "content": "", "timed_out": true,
        "bell_rung": false, "shell_exited": false,
    })
}
