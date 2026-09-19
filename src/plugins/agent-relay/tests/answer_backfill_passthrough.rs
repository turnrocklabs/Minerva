// answer_backfill_passthrough.rs — the backfilled answer as Minerva receives it.
//
// Drives whole passthrough turns against the real binary with a fake host, so
// what is asserted is the delivered envelope, not an internal decision. The
// paired loss corpus supplies the terminal screen and the harness transcript
// for the same turn; the transcript is planted where that harness's binder
// looks, under scratch CLAUDE_CONFIG_DIR / CODEX_HOME roots.
//
// The expected screen-path text is never written by hand. Every case that must
// keep the scrape runs the same turn a second time against an EMPTY log tree,
// which is the pipeline with backfill made impossible, and compares.
//
// Planting re-stamps the transcript so its session sits just ahead of the send
// this test is about to make: backfill only hands back a turn that opened
// inside the submit window, and a fixture's recorded instant is fixed while the
// relay reads its own clock. Only the timestamp values change; every byte
// outside those values is the harness's own.
//
// host.terminal.wait is answered with synthetic idle/busy screens: turn
// detection is the watcher's business and must not depend on corpus content.
// host.terminal.read is answered with the corpus screen, which is what the
// cleaning pipeline and then the matcher actually see.

use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

// The crate's own turn path reaches every item here; a standalone include does not.
#[path = "../src/session_log.rs"]
#[allow(dead_code)]
mod session_log;
#[path = "../src/turn_extract.rs"]
#[allow(dead_code)]
mod turn_extract;

const TERMINAL: &str = "t-backfill";

/// How far ahead of now a planted session's first record is stamped. The first
/// record of every corpus transcript is the one that opens its turn, so this is
/// the distance between that turn and the send: big enough to cover the plugin
/// spawn and handshake that precede the send, and inside the submit window the
/// matcher requires (2s before to 15s after the submit).
const PLANT_AHEAD_MS: i64 = 8_000;

/// Epoch milliseconds now, for a test that stamps its own records.
fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock past the epoch")
        .as_millis() as i64
}

// ---------------------------------------------------------------------------
// Corpus access
// ---------------------------------------------------------------------------

fn corpus_dir(pair: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/loss_pairs")
        .join(pair)
}

fn corpus_file(pair: &str, name: &str) -> String {
    let path = corpus_dir(pair).join(name);
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// The prompt as the relay would have submitted it. The corpus annotates an
/// interrupted pair with the operator's Esc timing, which was never typed.
fn corpus_prompt(pair: &str) -> String {
    let meta: Value = serde_json::from_str(&corpus_file(pair, "meta.json")).expect("meta.json");
    let prompt = meta["prompt"].as_str().expect("meta prompt");
    match prompt.rfind("  (Esc at +") {
        Some(at) if prompt.ends_with("s)") => prompt[..at].to_string(),
        _ => prompt.to_string(),
    }
}

/// First record of a transcript: the claude cwd and the day a rollout belongs
/// in both come from the log itself, so no fixture bytes are rewritten.
fn first_record(jsonl: &str) -> Value {
    jsonl
        .lines()
        .find(|l| !l.trim().is_empty())
        .and_then(|l| serde_json::from_str(l).ok())
        .unwrap_or(Value::Null)
}

// ---------------------------------------------------------------------------
// Scratch harness-log roots
// ---------------------------------------------------------------------------

/// A scratch home holding the two harness log roots, removed on drop.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Scratch {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "agent-relay-backfill-it-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst),
        ));
        fs::create_dir_all(&dir).expect("scratch home");
        Scratch(dir)
    }

    fn claude_config(&self) -> PathBuf {
        self.0.join("claude")
    }

    fn codex_home(&self) -> PathBuf {
        self.0.join("codex")
    }

    /// Plant a transcript where its harness's binder looks, re-stamped onto
    /// this run's clock. An empty fixture is a session the harness wrote no
    /// file for, so nothing is planted.
    fn plant(&self, profile: &str, jsonl: &str) {
        if jsonl.trim().is_empty() {
            return;
        }
        let jsonl = &restamp(jsonl);
        let first = first_record(jsonl);
        let (dir, name) = if profile == "claude" {
            let cwd = first["cwd"].as_str().expect("claude record cwd");
            (
                self.claude_config().join("projects").join(claude_slug(cwd)),
                "session.jsonl".to_string(),
            )
        } else {
            let day = first["timestamp"]
                .as_str()
                .and_then(|ts| ts.split('T').next())
                .expect("rollout timestamp");
            (
                self.codex_home()
                    .join("sessions")
                    .join(day.replace('-', "/")),
                format!("rollout-{day}.jsonl"),
            )
        };
        fs::create_dir_all(&dir).expect("log directory");
        fs::write(dir.join(name), jsonl).expect("plant transcript");
    }

    /// Plant a claude transcript under a name of the test's choosing, byte for
    /// byte: a test that stamps its own records must not have them shifted.
    fn plant_claude_as(&self, cwd: &str, name: &str, jsonl: &str) {
        let dir = self.claude_config().join("projects").join(claude_slug(cwd));
        fs::create_dir_all(&dir).expect("log directory");
        fs::write(dir.join(name), jsonl).expect("plant transcript");
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The records claude writes for one finished turn, stamped from `at_ms`: the
/// user record that opens it, the assistant text, and the turn_duration that
/// closes it.
fn claude_turn(cwd: &str, prompt: &str, answer: &str, at_ms: i64) -> String {
    [
        json!({"type": "user", "cwd": cwd, "timestamp": iso_from_ms(at_ms),
               "message": {"role": "user", "content": prompt}}),
        json!({"type": "assistant", "timestamp": iso_from_ms(at_ms + 1_000),
               "message": {"role": "assistant", "content": [{"type": "text", "text": answer}]}}),
        json!({"type": "system", "subtype": "turn_duration",
               "timestamp": iso_from_ms(at_ms + 1_100)}),
    ]
    .iter()
    .map(|r| r.to_string())
    .collect::<Vec<_>>()
    .join("\n")
        + "\n"
}

/// Claude Code's project directory name: every non-alphanumeric byte of the
/// absolute cwd becomes '-'.
fn claude_slug(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

// ---------------------------------------------------------------------------
// Re-stamping
// ---------------------------------------------------------------------------

/// Shift every recorded instant by one delta, so the session's first record
/// lands PLANT_AHEAD_MS from now and the order within it is untouched.
fn restamp(jsonl: &str) -> String {
    let stamp = regex::Regex::new(r#""timestamp"\s*:\s*"([^"]+)""#).expect("timestamp pattern");
    let now = now_ms();
    let first = stamp
        .captures_iter(jsonl)
        .find_map(|c| session_log::parse_iso_ms(&c[1]))
        .unwrap_or_else(|| panic!("transcript carries no readable timestamp"));
    let delta = now + PLANT_AHEAD_MS - first;

    stamp
        .replace_all(
            jsonl,
            |caps: &regex::Captures| match session_log::parse_iso_ms(&caps[1]) {
                Some(ms) => format!(r#""timestamp": "{}""#, iso_from_ms(ms + delta)),
                None => caps[0].to_string(),
            },
        )
        .into_owned()
}

/// Epoch milliseconds back into the "…T…Z" form both harnesses write.
fn iso_from_ms(ms: i64) -> String {
    let (year, month, day) = civil_from_days(ms.div_euclid(86_400_000));
    let rest = ms.rem_euclid(86_400_000);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        rest / 3_600_000,
        (rest / 60_000) % 60,
        (rest / 1_000) % 60,
        rest % 1_000,
    )
}

/// Civil date of a day count since 1970-01-01 (Hinnant's algorithm), the
/// inverse of the one the binder parses timestamps with.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let shifted = days + 719_468;
    let era = if shifted >= 0 {
        shifted
    } else {
        shifted - 146_096
    } / 146_097;
    let day_of_era = shifted - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400;
    (if month <= 2 { year + 1 } else { year }, month, day)
}

// ---------------------------------------------------------------------------
// Fake host
// ---------------------------------------------------------------------------

/// A settled screen showing the profile's prompt box and no busy marker —
/// what the watcher reads as a finished turn.
fn idle_screen(profile: &str) -> &'static str {
    match profile {
        "codex" => "Here is my answer.\n\n\u{203a} Ask Codex to do anything\n",
        _ => "Here is my answer.\n\u{273b} Baked for 3s\n\n\u{276f}\u{a0}\n? for shortcuts\n",
    }
}

/// Both profiles take the literal interrupt hint as their busy marker.
fn busy_screen(profile: &str) -> &'static str {
    match profile {
        "codex" => "\u{2022} Working (3s \u{b7} esc to interrupt)\n\n\u{203a} \n",
        _ => "\u{2736} Pondering\u{2026} (3s \u{b7} esc to interrupt)\n\n\u{276f}\u{a0}\n",
    }
}

fn send_cap_reply(stdin: &mut ChildStdin, id: &Value, result: Value) {
    let reply = json!({"jsonrpc": "2.0", "id": id, "result": {"success": true, "result": result}});
    stdin
        .write_all((reply.to_string() + "\n").as_bytes())
        .expect("write cap reply");
    stdin.flush().expect("flush cap reply");
}

fn write_request(stdin: &mut ChildStdin, req: &Value) {
    stdin
        .write_all((req.to_string() + "\n").as_bytes())
        .expect("write request");
    stdin.flush().expect("flush request");
}

/// One whole passthrough turn against a live plugin, with nothing installed
/// beforehand.
fn deliver(scratch: &Scratch, profile: &str, cwd: &str, prompt: &str, screen: &str) -> Value {
    deliver_after(scratch, profile, cwd, prompt, screen, &[])
}

/// One whole passthrough turn against a live plugin: handshake, watch_start,
/// each `setup` tool call in order, then passthrough_generate, answering every
/// capability the plugin asks for. Returns the delivered envelope.
fn deliver_after(
    scratch: &Scratch,
    profile: &str,
    cwd: &str,
    prompt: &str,
    screen: &str,
    setup: &[Value],
) -> Value {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let tag = NEXT.fetch_add(1, Ordering::SeqCst);
    let state_file = std::env::temp_dir().join(format!(
        "agent-relay-backfill-state-{}-{tag}.json",
        std::process::id(),
    ));
    let mut child: Child = Command::new(env!("CARGO_BIN_EXE_agent-relay-plugin"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env("AGENT_RELAY_STATE_FILE", &state_file)
        .env("CLAUDE_CONFIG_DIR", scratch.claude_config())
        .env("CODEX_HOME", scratch.codex_home())
        .spawn()
        .expect("spawn agent-relay-plugin");
    let mut stdin = child.stdin.take().expect("stdin");
    let mut out = BufReader::new(child.stdout.take().expect("stdout"));

    write_request(
        &mut stdin,
        &json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    );
    write_request(
        &mut stdin,
        &json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
    );
    write_request(
        &mut stdin,
        &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
            "name": "minerva_agent_relay_watch_start",
            "arguments": {"terminal_id": TERMINAL, "profile": profile, "notify_mode": "armed"}
        }}),
    );
    for (index, call) in setup.iter().enumerate() {
        write_request(
            &mut stdin,
            &json!({"jsonrpc": "2.0", "id": 100 + index, "method": "tools/call",
                    "params": call}),
        );
    }
    write_request(
        &mut stdin,
        &json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
            "name": "minerva_agent_relay_passthrough_generate",
            "arguments": {"chat_id": "chat-backfill", "entry_id": format!("terminal-{TERMINAL}"),
                          "text": prompt}
        }}),
    );

    let mut waits = 0u32;
    let mut reads = 0u32;
    let mut envelope: Option<Value> = None;
    for _ in 0..400 {
        let mut buf = String::new();
        if out.read_line(&mut buf).expect("read line") == 0 {
            break;
        }
        let Ok(msg) = serde_json::from_str::<Value>(buf.trim()) else {
            continue;
        };
        if msg.get("method").and_then(|m| m.as_str()) == Some("minerva/capability") {
            let id = msg.get("id").cloned().unwrap_or(Value::Null);
            let reply = match msg["params"]["capability"].as_str().unwrap_or("") {
                "host.terminal.list" => json!({"terminals": [
                    {"id": TERMINAL, "cwd": cwd, "created_at_ms": 0}
                ]}),
                "host.terminal.write" => json!({"ok": true}),
                // The FIRST read is send's pre-write snapshot; every later one
                // is read_turn's turn window, which may be taken twice when
                // the echo anchor is not in the wide window.
                "host.terminal.read" => {
                    reads += 1;
                    let content = if reads == 1 {
                        idle_screen(profile)
                    } else {
                        screen
                    };
                    json!({"content": content, "rows": 40, "total_scrollback_rows": 55})
                }
                "host.terminal.wait" => {
                    waits += 1;
                    let (content, rows) = match waits {
                        1 => (idle_screen(profile), 40),
                        2 => (busy_screen(profile), 42),
                        _ => (idle_screen(profile), 55),
                    };
                    json!({"content": content, "timed_out": false, "bell_rung": false,
                           "shell_exited": false, "rows": 40, "total_scrollback_rows": rows})
                }
                _ => json!({}),
            };
            send_cap_reply(&mut stdin, &id, reply);
        } else if msg.get("id") == Some(&json!(3)) {
            envelope = Some(msg);
            break;
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    let _ = fs::remove_file(&state_file);

    let reply = envelope.expect("passthrough_generate replied");
    let text = reply["result"]["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("no tool content: {reply}"));
    serde_json::from_str(text).unwrap_or_else(|e| panic!("content not JSON ({e}): {text}"))
}

/// The same turn with and without the harness transcript in reach. The second
/// run IS the pre-backfill pipeline, so it defines the screen-path expectation.
fn deliver_both(pair: &str, profile: &str) -> (Value, Value) {
    let prompt = corpus_prompt(pair);
    let screen = corpus_file(pair, "screen.txt");
    let log = corpus_file(pair, "session_log.jsonl");
    let cwd = first_record(&log)["cwd"]
        .as_str()
        .unwrap_or("/nonexistent")
        .to_string();

    let bound = Scratch::new();
    bound.plant(profile, &log);
    let with_log = deliver(&bound, profile, &cwd, &prompt, &screen);

    let bare = Scratch::new();
    let without_log = deliver(&bare, profile, &cwd, &prompt, &screen);
    (with_log, without_log)
}

fn answer_text(envelope: &Value) -> &str {
    assert_eq!(envelope["kind"], "answer", "delivered kind: {envelope}");
    envelope["text"].as_str().expect("answer text")
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A turn whose screen lost the markdown source is delivered from the log, and
/// the envelope names the source. The same turn with no log in reach delivers
/// the screen text unchanged — the shape every existing consumer already reads.
#[test]
fn markdown_turn_is_delivered_from_the_log_and_names_its_source() {
    for (pair, profile) in [
        ("claude/02_markdown_source", "claude"),
        ("codex/03_markdown_source", "codex"),
    ] {
        let truth = corpus_file(pair, "ground_truth.txt");
        let (with_log, without_log) = deliver_both(pair, profile);

        assert_eq!(
            answer_text(&with_log),
            truth,
            "{pair}: the harness's own markdown is delivered"
        );
        assert_eq!(with_log["answer_source"], "log", "{pair}: {with_log}");
        assert!(
            !answer_text(&with_log).contains("done 7:3")
                && !answer_text(&with_log).contains('\u{273b}'),
            "{pair}: the completion-glyph status line is gone"
        );

        let scraped = answer_text(&without_log);
        assert_eq!(
            without_log["answer_source"], "screen",
            "{pair}: {without_log}"
        );
        assert_ne!(scraped, truth, "{pair}: the screen path really did lose it");
        assert!(
            without_log["kind"].is_string() && without_log["text"].is_string(),
            "{pair}: a consumer reading only kind and text sees the same shape"
        );
    }
}

/// The three ways a turn has no recorded answer — the harness wrote no log at
/// all, and an aborted turn it wrote nothing into — deliver exactly what the
/// pre-backfill pipeline delivered.
#[test]
fn turns_without_a_recorded_answer_deliver_the_screen_text_byte_for_byte() {
    for (pair, profile) in [
        ("claude/06_slash_command", "claude"),
        ("codex/05_slash_command", "codex"),
        ("codex/04_interrupted", "codex"),
    ] {
        let (with_log, without_log) = deliver_both(pair, profile);
        assert_eq!(
            answer_text(&with_log),
            answer_text(&without_log),
            "{pair}: nothing to backfill, so the scrape is untouched"
        );
        assert_eq!(with_log["answer_source"], "screen", "{pair}: {with_log}");
        assert!(
            !answer_text(&with_log).is_empty(),
            "{pair}: the screen is still the answer"
        );
    }
}

/// Backfilled text is held to the redaction rules scraped text is: a secret
/// the harness recorded and the screen never showed does not reach the chat.
#[test]
fn a_secret_only_the_log_holds_is_redacted_before_delivery() {
    // A classic-token shape the redactor must see whole, assembled at run time:
    // the same 40 characters written as one literal are a credential pattern
    // the repository's secret scan refuses in any commit.
    let token = format!("gh{}_{}", 'p', "aA1Bb2Cc3Dd4".repeat(3));
    let cwd = "/scratch/secret-proj";
    let prompt = "where is the deploy token";
    let answer = format!(
        "## Credentials\n\nThe deploy token for the staging cluster is {token} and it must \
         never be pasted into a shared channel. Rotate it from the settings page if it has \
         ever appeared in a transcript."
    );
    let log = [
        json!({"type": "user", "cwd": cwd, "timestamp": "2026-09-19T01:00:00.000Z",
               "message": {"role": "user", "content": prompt}}),
        json!({"type": "assistant", "timestamp": "2026-09-19T01:00:04.000Z",
               "message": {"role": "assistant", "content": [{"type": "text", "text": answer}]}}),
        json!({"type": "system", "subtype": "turn_duration",
               "timestamp": "2026-09-19T01:00:05.000Z"}),
    ]
    .iter()
    .map(|r| r.to_string())
    .collect::<Vec<_>>()
    .join("\n")
        + "\n";

    // The screen carries the same prose with the secret absent, so redaction
    // of the delivered text can only have run on the backfilled copy.
    let screen = format!(
        "Claude Code v2.1.277\n\n\u{276f} {prompt}\n\n\u{25cf} Credentials\n\n  The deploy \
         token for the staging cluster is not shown here and it must never be pasted into\n  \
         a shared channel. Rotate it from the settings page if it has ever appeared in a \
         transcript.\n\n\u{273b} Cogitated for 2s \u{b7} done 7:30 PM\n\n\u{276f}\u{a0}\n\
         ? for shortcuts\n"
    );

    let scratch = Scratch::new();
    scratch.plant("claude", &log);
    let envelope = deliver(&scratch, "claude", cwd, prompt, &screen);

    let delivered = answer_text(&envelope);
    assert_eq!(envelope["answer_source"], "log", "{envelope}");
    assert!(
        delivered.contains("## Credentials"),
        "the log's markdown was delivered: {delivered:?}"
    );
    assert!(
        !delivered.contains(token.as_str()),
        "the recorded secret must not reach the chat: {delivered:?}"
    );
    assert!(
        delivered.contains("[REDACTED:github_token]"),
        "redaction ran on the backfilled text: {delivered:?}"
    );
}

/// Two terminals in one directory both sent "continue", and only the sibling's
/// transcript has been flushed. The submit window is the only thing that can
/// separate them, and where it cannot, the binder's refusal is what is left.
///
/// A sibling turn 40s past our submit is outside the window, so the screen text
/// stands. A sibling turn inside the window is separated by nothing the relay
/// can see — same directory, same prompt, a stamp a harness could plausibly
/// have put on our turn — and the scrape here is too short to cross-check it
/// with; that file was just bound, so its window vouches for no turn and the
/// answer is refused rather than delivered. The moment our own transcript
/// exists the binder sees two candidates holding the prompt, refuses both as
/// ambiguous, and the sibling's answer stops being reachable at all.
#[test]
fn a_siblings_turn_is_kept_out_by_the_window_and_then_by_the_binder() {
    const CWD: &str = "/scratch/sibling-proj";
    const PROMPT: &str = "continue";
    const SIBLING: &str = "Done - I rewrote the parser and every test passes.";
    const OURS: &str = "Done - I updated the changelog.";
    // Our terminal's screen. It cleans down to one word, which is under the
    // cross-check threshold and also appears in the sibling's answer.
    let screen = "\u{276f} continue\n\n\u{25cf} Done\n";

    let far = Scratch::new();
    far.plant_claude_as(
        CWD,
        "sibling.jsonl",
        &claude_turn(CWD, PROMPT, SIBLING, now_ms() + 40_000),
    );
    let outside = deliver(&far, "claude", CWD, PROMPT, screen);
    assert_eq!(outside["answer_source"], "screen", "{outside}");
    assert!(
        !answer_text(&outside).contains("rewrote the parser"),
        "a turn outside the submit window is another turn: {outside}"
    );

    let near = Scratch::new();
    near.plant_claude_as(
        CWD,
        "sibling.jsonl",
        &claude_turn(CWD, PROMPT, SIBLING, now_ms() + PLANT_AHEAD_MS),
    );
    let inside = deliver(&near, "claude", CWD, PROMPT, screen);
    assert_eq!(
        inside["answer_source"], "screen",
        "a scrape too short to cross-check may not ride on a file just \
         bound: {inside}"
    );
    assert!(
        !answer_text(&inside).contains("rewrote the parser"),
        "the sibling's answer is refused, not delivered: {inside}"
    );

    let both = Scratch::new();
    both.plant_claude_as(
        CWD,
        "sibling.jsonl",
        &claude_turn(CWD, PROMPT, SIBLING, now_ms() + PLANT_AHEAD_MS),
    );
    both.plant_claude_as(
        CWD,
        "ours.jsonl",
        &claude_turn(CWD, PROMPT, OURS, now_ms() + PLANT_AHEAD_MS + 1_000),
    );
    let ambiguous = deliver(&both, "claude", CWD, PROMPT, screen);
    assert_eq!(ambiguous["answer_source"], "screen", "{ambiguous}");
    assert!(
        !answer_text(&ambiguous).contains("rewrote the parser"),
        "two candidates holding the prompt are refused, not picked: {ambiguous}"
    );
}

/// A named filter rule is part of the pipeline, not a screen-path decoration:
/// it masks the token wherever the delivered text came from. The token appears
/// only in the harness's record, so a masked form in the delivered text can
/// only mean the rule ran on the backfilled answer.
#[test]
fn a_named_filter_rule_masks_a_token_the_log_alone_holds() {
    const CWD: &str = "/scratch/rule-proj";
    const PROMPT: &str = "what is the staging host";
    const TOKEN: &str = "staging-9f3a.internal";
    let answer = format!(
        "## Staging\n\nThe box is {TOKEN} and the deploy runs from there. Ask before \
         restarting it, because the release job holds a lock on the shared build cache \
         for the whole rollout, and a restart in the middle of that loses the cache."
    );
    // The same prose on screen with the host absent: the rule can only see the
    // token by way of the log. The shared prose is long enough that the three
    // words only the log holds stay inside the matcher's coverage rule.
    let screen = format!(
        "\u{276f} {PROMPT}\n\n\u{25cf} Staging\n\n  The box is not shown here and the \
         deploy runs from there. Ask before\n  restarting it, because the release job \
         holds a lock on the shared build\n  cache for the whole rollout, and a restart \
         in the middle of that loses\n  the cache.\n\n\u{273b} Cogitated for \
         2s\n\n\u{276f}\u{a0}\n? for shortcuts\n"
    );

    let scratch = Scratch::new();
    scratch.plant_claude_as(
        CWD,
        "session.jsonl",
        &claude_turn(CWD, PROMPT, &answer, now_ms() + PLANT_AHEAD_MS),
    );
    let envelope = deliver_after(
        &scratch,
        "claude",
        CWD,
        PROMPT,
        &screen,
        &[json!({
            "name": "minerva_agent_relay_filter_set",
            "arguments": {"name": "mask-staging-host", "pattern": TOKEN,
                          "action": "replace", "replacement": "[internal host]"}
        })],
    );

    let delivered = answer_text(&envelope);
    assert_eq!(envelope["answer_source"], "log", "{envelope}");
    assert!(
        delivered.contains("## Staging"),
        "the log's markdown was delivered: {delivered:?}"
    );
    assert!(
        !delivered.contains(TOKEN),
        "the rule ran on the backfilled answer: {delivered:?}"
    );
    assert!(
        delivered.contains("[internal host]"),
        "the delivered text carries the masked form: {delivered:?}"
    );
}

/// A transcript far larger than either byte budget. Binding reads the prompt
/// window from the end of the file and extraction opens on the tail window, so
/// a turn inside those windows is delivered exactly as it is from a small file,
/// and a turn buried behind more padding than the extraction window holds is
/// not offered at all — the screen text stands.
#[test]
fn an_oversized_transcript_stays_within_budget_or_falls_back_to_the_screen() {
    const CWD: &str = "/scratch/huge-proj";
    const PROMPT: &str = "summarise the parser change";
    const ANSWER: &str = "## Parser\n\nThe tokeniser now folds escapes before the lexer \
                          sees them, which is why the fixture changed.";
    let screen = "\u{276f} summarise the parser change\n\n\u{25cf} Parser\n\n  The \
                  tokeniser now folds escapes before the lexer sees them, which is\n  why \
                  the fixture changed.\n\n\u{273b} Cogitated for 2s\n\n\u{276f}\u{a0}\n\
                  ? for shortcuts\n";
    let at = now_ms() + PLANT_AHEAD_MS;
    let turn = claude_turn(CWD, PROMPT, ANSWER, at);

    let small = Scratch::new();
    small.plant_claude_as(CWD, "session.jsonl", &turn);
    let plain = deliver(&small, "claude", CWD, PROMPT, screen);
    assert_eq!(plain["answer_source"], "log", "{plain}");

    // Everything the prompt scan must read past to reach the prompt, and
    // everything the extraction window must skip to reach the turn.
    let leading = padding(CWD, at - 60_000, session_log::PROMPT_SCAN_BYTES + 64 * 1024);
    let buried = Scratch::new();
    buried.plant_claude_as(CWD, "session.jsonl", &format!("{leading}{turn}"));
    let deep = deliver(&buried, "claude", CWD, PROMPT, screen);
    assert_eq!(
        deep["answer_source"], "log",
        "a turn inside both windows binds and extracts: {deep}"
    );
    assert_eq!(
        answer_text(&deep),
        answer_text(&plain),
        "the size of the history before the turn changes nothing"
    );

    // The prompt is still inside the prompt window, so the file binds; the turn
    // is not inside the extraction window, so no turn is offered.
    let trailing = padding(
        CWD,
        at + 2_000,
        turn_extract::FRESH_BIND_TAIL_BYTES + 64 * 1024,
    );
    let past = Scratch::new();
    past.plant_claude_as(CWD, "session.jsonl", &format!("{turn}{trailing}"));
    let beyond = deliver(&past, "claude", CWD, PROMPT, screen);
    assert_eq!(
        beyond["answer_source"], "screen",
        "a turn behind more records than the tail window holds is not offered: {beyond}"
    );
    let bare = Scratch::new();
    assert_eq!(
        answer_text(&beyond),
        answer_text(&deliver(&bare, "claude", CWD, PROMPT, screen)),
        "and the screen text is delivered untouched"
    );
}

/// At least `bytes` of records the extractor steps over, carrying the cwd and
/// stamps a harness would write so that nothing but their size matters.
fn padding(cwd: &str, at_ms: i64, bytes: u64) -> String {
    let filler = "x".repeat(4_096);
    let mut out = String::with_capacity(bytes as usize + 8_192);
    let mut index = 0i64;
    while out.len() < bytes as usize {
        out.push_str(
            &json!({"type": "system", "subtype": "padding", "cwd": cwd,
                    "timestamp": iso_from_ms(at_ms + index), "filler": filler})
            .to_string(),
        );
        out.push('\n');
        index += 1;
    }
    out
}
