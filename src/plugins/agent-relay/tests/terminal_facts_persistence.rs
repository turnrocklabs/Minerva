// terminal_facts_persistence.rs — do the binder's facts survive a relay
// restart, and do they still bind afterwards?
//
// Two halves, both against real paths:
//   in-process — facts read back out of a persisted session object convert to
//                TerminalFacts and bind a constructed claude log layout; a
//                session object written by a relay that predates the fields
//                loads with the facts absent.
//   end-to-end — the plugin binary driven by a fake Minerva host: watch_start
//                against a listing carrying cwd + created_at_ms, one prompt
//                sent, process killed, then a SECOND process on the same state
//                file whose host reports neither field. What the first process
//                learned has to come back out of the file, not the host.
//
// The crate is a binary, so both modules are pulled in by path, as the other
// test files do.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{json, Map, Value};

#[path = "../src/session_log.rs"]
mod session_log;
#[path = "../src/terminal_facts.rs"]
mod terminal_facts;

use session_log::{Binding, LogRoots};
use terminal_facts::{SessionFacts, MAX_PROMPTS};

static COUNTER: AtomicU64 = AtomicU64::new(7000);

fn next_id() -> u64 {
    COUNTER.fetch_add(1, Ordering::SeqCst)
}

fn scratch(tag: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "agent-relay-facts-{}-{}-{}",
        std::process::id(),
        next_id(),
        tag
    ));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).unwrap();
    path
}

// ---------------------------------------------------------------------------
// In-process: persisted object → facts → binding
// ---------------------------------------------------------------------------

/// One claude user record: everything the binder reads out of a head scan
/// plus the prompt evidence.
fn claude_record(cwd: &str, timestamp: &str, prompt: &str) -> String {
    json!({
        "type": "user",
        "cwd": cwd,
        "timestamp": timestamp,
        "message": {"role": "user", "content": prompt},
    })
    .to_string()
        + "\n"
}

fn write_claude_log(home: &Path, cwd: &str, name: &str, body: &str) -> PathBuf {
    let dir = home
        .join(".claude/projects")
        .join(session_log::claude_project_slug(Path::new(cwd)));
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join(format!("{name}.jsonl"));
    fs::write(&path, body).unwrap();
    path
}

/// The facts a relay persisted are enough, on their own, to pick one of two
/// sibling transcripts that share a cwd and a time window — the prompt is the
/// only thing that tells them apart.
#[test]
fn persisted_facts_convert_and_bind() {
    let home = scratch("bind");
    let cwd = home.join("proj");
    fs::create_dir_all(&cwd).unwrap();
    let cwd_str = cwd.to_string_lossy().to_string();

    let ours = write_claude_log(
        &home,
        &cwd_str,
        "session-ours",
        &claude_record(&cwd_str, "2026-09-18T10:00:00.000Z", "count the widgets"),
    );
    let theirs = write_claude_log(
        &home,
        &cwd_str,
        "session-theirs",
        &claude_record(&cwd_str, "2026-09-18T10:00:01.000Z", "rename the widgets"),
    );
    assert_ne!(ours, theirs);

    // Exactly the object state.rs writes into the state file.
    let mut persisted = Map::new();
    persisted.insert("terminal_id".to_string(), json!("t-facts"));
    persisted.insert("profile_id".to_string(), json!("claude"));
    persisted.insert("notify_mode".to_string(), json!("armed"));
    let mut saved = SessionFacts {
        cwd: Some(cwd_str.clone()),
        start_ms: Some(1_600_000_000_000),
        ..Default::default()
    };
    saved.record_prompt("count the widgets");
    saved.write_into(&mut persisted);

    let reloaded = SessionFacts::from_json(&Value::Object(persisted));
    assert_eq!(reloaded, saved, "facts survive the state-file round trip");

    let roots = LogRoots::for_home(&home);
    assert_eq!(
        session_log::bind(&reloaded.to_terminal_facts("claude"), &roots),
        Binding::Bound(ours.clone()),
        "the reloaded prompt picks our transcript"
    );

    // Drop the prompt evidence and the two siblings are indistinguishable —
    // proof the binding above came from the facts, not from the layout.
    let mut promptless = reloaded.clone();
    promptless.prompts.clear();
    let mut both = vec![ours, theirs];
    both.sort();
    assert_eq!(
        session_log::bind(&promptless.to_terminal_facts("claude"), &roots),
        Binding::Ambiguous(both),
        "without prompts the siblings stay ambiguous"
    );

    let _ = fs::remove_dir_all(&home);
}

/// A session object written before these fields existed loads as absent facts,
/// and those facts prune nothing.
#[test]
fn legacy_session_object_loads_without_facts() {
    let legacy = json!({
        "terminal_id": "t-old",
        "profile_id": "codex",
        "notify_mode": "all_turns",
    });
    let facts = SessionFacts::from_json(&legacy);
    assert_eq!(facts, SessionFacts::default());

    let bound = facts.to_terminal_facts("codex");
    assert!(bound.cwd.is_none(), "no cwd is invented");
    assert_eq!(bound.window_start_ms, 0, "no start time prunes nothing");
    assert!(bound.prompts.is_empty());
}

// ---------------------------------------------------------------------------
// End-to-end: the plugin binary against a fake Minerva host
// ---------------------------------------------------------------------------

const TERMINAL_ID: &str = "t-facts-e2e";
const LAUNCH_CWD: &str = "/work/facts-proj";
const CREATED_AT_MS: i64 = 1_600_000_000_000_i64;

struct Plugin {
    child: Child,
    stdin: ChildStdin,
    out: BufReader<ChildStdout>,
}

impl Plugin {
    fn spawn(state_file: &Path) -> Plugin {
        let mut child = Command::new(env!("CARGO_BIN_EXE_agent-relay-plugin"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("AGENT_RELAY_STATE_FILE", state_file)
            .spawn()
            .expect("spawn agent-relay-plugin");
        let stdin = child.stdin.take().expect("stdin");
        let out = BufReader::new(child.stdout.take().expect("stdout"));
        Plugin { child, stdin, out }
    }

    fn write(&mut self, value: &Value) {
        let line = value.to_string() + "\n";
        self.stdin.write_all(line.as_bytes()).expect("write");
        self.stdin.flush().expect("flush");
    }

    fn handshake(&mut self, listing: &Value) {
        let id = next_id();
        self.call(
            json!({"jsonrpc": "2.0", "id": id, "method": "initialize", "params": {}}),
            listing,
        );
        self.write(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));
    }

    /// Send one request and pump the plugin's output until its reply arrives,
    /// answering every capability request the watch thread makes meanwhile.
    fn call(&mut self, request: Value, listing: &Value) -> Value {
        let want = request.get("id").cloned();
        self.write(&request);
        for _ in 0..400 {
            let mut buf = String::new();
            let n = self.out.read_line(&mut buf).expect("read line");
            if n == 0 {
                panic!("plugin EOF waiting for {want:?}");
            }
            let Ok(msg) = serde_json::from_str::<Value>(buf.trim()) else {
                continue;
            };
            if msg.get("method").and_then(|m| m.as_str()) == Some("minerva/capability") {
                let id = msg.get("id").cloned().unwrap_or(Value::Null);
                let reply = match msg["params"]["capability"].as_str().unwrap_or("") {
                    "host.terminal.list" => listing.clone(),
                    // Quiet: an idle timeout keeps the detector from emitting.
                    "host.terminal.wait" => json!({
                        "content": "", "timed_out": true,
                        "bell_rung": false, "shell_exited": false
                    }),
                    "host.terminal.read" => json!({
                        "content": "\u{276f}\u{a0}\n", "total_scrollback_rows": 12
                    }),
                    _ => json!({}),
                };
                self.write(&json!({
                    "jsonrpc": "2.0", "id": id,
                    "result": {"success": true, "result": reply}
                }));
                continue;
            }
            if msg.get("id").is_some() && msg.get("id") == want.as_ref() {
                return msg;
            }
        }
        panic!("no reply to {want:?}");
    }

    fn tool(&mut self, name: &str, arguments: Value, listing: &Value) -> Value {
        let reply = self.call(
            json!({
                "jsonrpc": "2.0",
                "id": next_id(),
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            }),
            listing,
        );
        let text = reply["result"]["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("no tool content: {reply}"));
        serde_json::from_str(text).unwrap_or_else(|e| panic!("content not JSON ({e}): {text}"))
    }

    fn kill(mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn listing_with_facts() -> Value {
    json!({"terminals": [{
        "id": TERMINAL_ID,
        "name": "agent",
        "visible": false,
        "alive": true,
        "cols": 80,
        "rows": 24,
        "cwd": LAUNCH_CWD,
        "created_at_ms": CREATED_AT_MS,
    }], "count": 1})
}

/// An older Minerva: the terminal is there, the facts are not.
fn listing_without_facts() -> Value {
    json!({"terminals": [{
        "id": TERMINAL_ID,
        "name": "agent",
        "visible": false,
        "alive": true,
        "cols": 80,
        "rows": 24,
    }], "count": 1})
}

fn persisted_session(state_file: &Path) -> Value {
    let raw = fs::read_to_string(state_file).expect("state file written");
    let doc: Value = serde_json::from_str(&raw).expect("state file parses");
    doc["sessions"]
        .as_array()
        .and_then(|list| {
            list.iter()
                .find(|s| s["terminal_id"] == TERMINAL_ID)
                .cloned()
        })
        .unwrap_or_else(|| panic!("no session for {TERMINAL_ID}: {doc}"))
}

/// The whole restart-survival claim in one run: what the first process learns
/// from the host and from its own send path has to come back out of the state
/// file in a second process whose host reports nothing.
#[test]
fn facts_survive_a_relay_restart() {
    let dir = scratch("restart");
    let state_file = dir.join("agent_relay_state.json");

    {
        let mut plugin = Plugin::spawn(&state_file);
        let listing = listing_with_facts();
        plugin.handshake(&listing);
        let started = plugin.tool(
            "minerva_agent_relay_watch_start",
            json!({"terminal_id": TERMINAL_ID, "profile": "claude", "notify_mode": "armed"}),
            &listing,
        );
        assert_eq!(started["ok"], true, "watch_start: {started}");

        let sent = plugin.tool(
            "minerva_agent_relay_send",
            json!({"terminal_id": TERMINAL_ID, "text": "count the widgets"}),
            &listing,
        );
        assert_eq!(sent["ok"], true, "send: {sent}");
        plugin.kill();
    }

    let session = persisted_session(&state_file);
    assert_eq!(
        session["cwd"], LAUNCH_CWD,
        "launch cwd persisted: {session}"
    );
    assert_eq!(session["start_ms"], CREATED_AT_MS, "start time persisted");
    assert_eq!(session["prompts"], json!(["count the widgets"]));

    {
        // Same state file, a host that knows neither field: only the reloaded
        // registry can still hold them.
        let mut plugin = Plugin::spawn(&state_file);
        let listing = listing_without_facts();
        plugin.handshake(&listing);
        let sent = plugin.tool(
            "minerva_agent_relay_send",
            json!({"terminal_id": TERMINAL_ID, "text": "now rename them"}),
            &listing,
        );
        assert_eq!(sent["ok"], true, "send after restart: {sent}");
        plugin.kill();
    }

    let session = persisted_session(&state_file);
    assert_eq!(session["cwd"], LAUNCH_CWD, "cwd survived the restart");
    assert_eq!(session["start_ms"], CREATED_AT_MS, "start time survived");
    assert_eq!(
        session["prompts"],
        json!(["count the widgets", "now rename them"]),
        "the restarted relay appended to the persisted prompts"
    );

    // The reloaded facts are the binder's input, unchanged in meaning.
    let facts = SessionFacts::from_json(&session);
    let bound = facts.to_terminal_facts("claude");
    assert_eq!(bound.cwd.as_deref(), Some(Path::new(LAUNCH_CWD)));
    assert_eq!(bound.window_start_ms, CREATED_AT_MS);
    assert_eq!(bound.prompts.len(), 2);
    assert!(bound.prompts.len() <= MAX_PROMPTS);

    let _ = fs::remove_dir_all(&dir);
}

/// A state file written by a relay that predates the facts fields must load,
/// resume its watch, and simply report no facts.
#[test]
fn legacy_state_file_resumes_without_facts() {
    let dir = scratch("legacy");
    let state_file = dir.join("agent_relay_state.json");
    fs::write(
        &state_file,
        json!({
            "version": 1,
            "profiles": [],
            "filter_rules": [],
            "sessions": [{
                "terminal_id": TERMINAL_ID,
                "profile_id": "claude",
                "notify_mode": "armed",
            }],
        })
        .to_string(),
    )
    .unwrap();

    let mut plugin = Plugin::spawn(&state_file);
    // Empty listing: the resumed watch learns nothing the file did not carry.
    let listing = json!({"terminals": [], "count": 0});
    plugin.handshake(&listing);
    let status = plugin.tool(
        "minerva_agent_relay_watch_status",
        json!({"terminal_id": TERMINAL_ID}),
        &listing,
    );
    assert_eq!(
        status["status"]["watching"], true,
        "legacy session resumed: {status}"
    );
    plugin.kill();

    let session = persisted_session(&state_file);
    assert_eq!(
        session["cwd"],
        Value::Null,
        "absent, not invented: {session}"
    );
    assert_eq!(session["start_ms"], Value::Null);
    assert_eq!(session["prompts"], json!([]));

    let _ = fs::remove_dir_all(&dir);
}
