// session_log_binding.rs — does the binder find the right harness log?
//
// The corpus at tests/fixtures/loss_pairs holds eleven real turns with the
// session-log records the harness wrote for each (an empty session_log.jsonl
// means it wrote none). Every test below lays those real bytes out in a temp
// directory in the harness's own shape and asks the binder to find them again
// from nothing but profile, cwd, alive-window and the current prompt with the
// instant it was submitted — the one rule the binder judges a candidate by.
//
// The crate is a binary, so the module is pulled in by path, as the other
// test files do.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::Value;

// The crate's own turn path reaches every item here; a standalone include does not.
#[path = "../src/session_log.rs"]
#[allow(dead_code)]
mod session_log;

use session_log::{bind, Binding, LogRoots, TerminalFacts};

// ---------------------------------------------------------------------------
// Corpus access
// ---------------------------------------------------------------------------

/// One corpus pair, reduced to what a binder caller would know.
struct Pair {
    harness: String,
    name: String,
    /// Bytes of the harness's own log for the turn (empty = none written).
    log: Vec<u8>,
    /// Prompt as submitted, with the corpus's own "(Esc at +Ns)" annotation
    /// removed — that suffix records operator timing, it was never typed.
    prompt: String,
    /// Value of meta.json's session_log field (a rollout filename for codex).
    log_name: String,
    /// cwd as the claude records carry it; codex rollouts in the corpus are
    /// redacted down to the turn's records and hold no session_meta.
    recorded_cwd: Option<String>,
    /// Stamp on the record that opens the turn, which in every corpus
    /// transcript is its first record. The relay's own submit instant is
    /// nowhere in the corpus, and a harness stamps that record within a second
    /// of the Enter, so it is the submit instant to restate. 0 when no log was
    /// written, which is a prompt no stamp can match.
    submitted_ms: i64,
}

impl Pair {
    fn has_log(&self) -> bool {
        !self.log.is_empty()
    }
}

fn corpus_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/loss_pairs")
}

fn load_pairs() -> Vec<Pair> {
    let mut pairs = Vec::new();
    for harness in ["claude", "codex"] {
        let mut dirs: Vec<PathBuf> = fs::read_dir(corpus_root().join(harness))
            .expect("corpus harness directory")
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_dir())
            .collect();
        dirs.sort();
        for dir in dirs {
            let meta: Value =
                serde_json::from_str(&fs::read_to_string(dir.join("meta.json")).unwrap()).unwrap();
            let log = fs::read(dir.join("session_log.jsonl")).unwrap();
            let prompt = meta["prompt"]
                .as_str()
                .unwrap()
                .split(" (Esc at ")
                .next()
                .unwrap()
                .to_string();
            let recorded_cwd = first_record_field(&log, "cwd");
            let submitted_ms = first_record_field(&log, "timestamp")
                .and_then(|ts| session_log::parse_iso_ms(&ts))
                .unwrap_or(0);
            pairs.push(Pair {
                harness: harness.to_string(),
                name: dir.file_name().unwrap().to_string_lossy().into_owned(),
                log,
                prompt,
                log_name: meta["session_log"].as_str().unwrap().to_string(),
                recorded_cwd,
                submitted_ms,
            });
        }
    }
    assert_eq!(pairs.len(), 11, "corpus holds eleven pairs");
    pairs
}

fn first_record_field(log: &[u8], field: &str) -> Option<String> {
    String::from_utf8_lossy(log)
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find_map(|r| r.get(field)?.as_str().map(str::to_string))
}

// ---------------------------------------------------------------------------
// Layout construction
// ---------------------------------------------------------------------------

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A throwaway home directory holding harness-shaped log trees.
struct Home(PathBuf);

impl Home {
    fn new(tag: &str) -> Home {
        let path = std::env::temp_dir().join(format!(
            "agent-relay-binder-{}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst),
            tag,
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Home(path)
    }

    fn roots(&self) -> LogRoots {
        LogRoots::for_home(&self.0)
    }

    /// Place bytes where Claude Code would: projects/<cwd slug>/<name>.jsonl.
    fn claude_log(&self, cwd: &str, name: &str, bytes: &[u8]) -> PathBuf {
        let dir = self
            .0
            .join(".claude/projects")
            .join(session_log::claude_project_slug(Path::new(cwd)));
        write_under(&dir, &format!("{name}.jsonl"), bytes)
    }

    /// Place bytes where codex would: sessions/YYYY/MM/DD/<rollout name>.
    fn codex_log(&self, rollout_name: &str, bytes: &[u8]) -> PathBuf {
        let date = &rollout_name["rollout-".len()..][..10]; // YYYY-MM-DD
        let dir = self
            .0
            .join(".codex/sessions")
            .join(&date[0..4])
            .join(&date[5..7])
            .join(&date[8..10]);
        write_under(&dir, rollout_name, bytes)
    }

    /// (path, size, mtime) for every file under the home — the read-only proof.
    fn snapshot(&self) -> BTreeMap<PathBuf, (u64, std::time::SystemTime)> {
        let mut out = BTreeMap::new();
        collect_files(&self.0, &mut out);
        out
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn collect_files(dir: &Path, out: &mut BTreeMap<PathBuf, (u64, std::time::SystemTime)>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_files(&path, out);
        } else if let Ok(meta) = entry.metadata() {
            out.insert(path, (meta.len(), meta.modified().unwrap()));
        }
    }
}

fn write_under(dir: &Path, name: &str, bytes: &[u8]) -> PathBuf {
    fs::create_dir_all(dir).unwrap();
    let path = dir.join(name);
    fs::write(&path, bytes).unwrap();
    path
}

/// A codex session_meta opening record — the corpus rollouts are redacted down
/// to their turn records, so cwd/originator evidence has to be constructed.
fn codex_meta_line(cwd: &str, originator: &str, timestamp: &str) -> String {
    format!(
        "{{\"timestamp\": \"{timestamp}\", \"ordinal\": 0, \"type\": \"session_meta\", \
         \"payload\": {{\"id\": \"01a0b73e-19ab-7402-9459-3cdd9e73a816\", \
         \"timestamp\": \"{timestamp}\", \"cwd\": \"{cwd}\", \
         \"originator\": \"{originator}\", \"cli_version\": \"0.155.1\"}}}}\n"
    )
}

/// Binder input for a terminal whose last prompt is `current`, as the body it
/// was sent with and the epoch instant the relay submitted it. None is a
/// terminal the relay has sent nothing into.
fn facts(profile: &str, cwd: Option<&str>, current: Option<(&str, i64)>) -> TerminalFacts {
    TerminalFacts {
        profile_id: profile.to_string(),
        cwd: cwd.map(PathBuf::from),
        window_start_ms: 0,
        window_end_ms: None,
        current_prompt: current.map(|(text, _)| text.to_string()),
        current_submitted_ms: current.map_or(0, |(_, ms)| ms),
    }
}

/// Epoch milliseconds of a stamp written the way a harness writes them.
fn at(timestamp: &str) -> i64 {
    session_log::parse_iso_ms(timestamp).expect("readable stamp")
}

/// The spike directory the codex corpus turns ran in. Their rollouts carry no
/// session_meta, so this is asserted through a constructed one.
const CODEX_SPIKE_CWD: &str =
    "/private/tmp/claude-501/-Users-ipeerbhai-github-Minerva/spike/codex-proj";

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Every corpus turn, laid out together in one home: the five claude logs share
/// a project directory and the four codex rollouts share a day directory, so
/// only the prompts tell siblings apart. Each terminal must get its own file,
/// the two slash-command turns must report no log, and nothing on disk may
/// change.
#[test]
fn every_corpus_turn_binds_to_its_own_log() {
    let pairs = load_pairs();
    let home = Home::new("corpus");
    let mut expected: Vec<(usize, PathBuf)> = Vec::new();

    for (index, pair) in pairs.iter().enumerate() {
        if pair.harness == "claude" {
            // The no-log claude turn is laid down as an EMPTY file: a file
            // with no records is not evidence of a session.
            let cwd = pair.recorded_cwd.clone().unwrap_or_else(|| {
                pairs
                    .iter()
                    .find_map(|p| p.recorded_cwd.clone())
                    .expect("claude corpus records a cwd")
            });
            let session_id = first_record_field(&pair.log, "sessionId")
                .unwrap_or_else(|| format!("empty-{}", pair.name));
            let path = home.claude_log(&cwd, &session_id, &pair.log);
            if pair.has_log() {
                expected.push((index, path));
            }
        } else if pair.has_log() {
            // Codex names its rollout after the local start time; the corpus
            // records that name, so the real one is reproduced.
            let path = home.codex_log(&pair.log_name, &pair.log);
            expected.push((index, path));
        }
    }

    let before = home.snapshot();

    for (index, pair) in pairs.iter().enumerate() {
        let cwd = if pair.harness == "claude" {
            pair.recorded_cwd.as_deref()
        } else {
            None // no session_meta in the redacted rollouts to check against
        };
        let outcome = bind(
            &facts(
                &pair.harness,
                cwd,
                Some((pair.prompt.as_str(), pair.submitted_ms)),
            ),
            &home.roots(),
        );
        match expected.iter().find(|(i, _)| *i == index) {
            Some((_, path)) => assert_eq!(
                outcome,
                Binding::Bound(path.clone()),
                "{}/{} binds to its own log",
                pair.harness,
                pair.name
            ),
            None => assert_eq!(
                outcome,
                Binding::NoLog,
                "{}/{} wrote no log",
                pair.harness,
                pair.name
            ),
        }
    }

    assert_eq!(before, home.snapshot(), "binding touched no harness file");
}

/// Two sessions that share a cwd, a window and the prompt text cannot be told
/// apart, and a terminal with no prompt evidence cannot be told from its
/// neighbour either. Both must refuse rather than pick.
#[test]
fn indistinguishable_candidates_are_refused() {
    let pairs = load_pairs();
    let claude = pairs
        .iter()
        .find(|p| p.harness == "claude" && p.has_log())
        .unwrap();
    let codex = pairs
        .iter()
        .find(|p| p.harness == "codex" && p.has_log())
        .unwrap();
    let cwd = claude.recorded_cwd.clone().unwrap();

    let home = Home::new("ambiguous");
    let a = home.claude_log(&cwd, "aaaaaaaa-1111-4111-8111-111111111111", &claude.log);
    let b = home.claude_log(&cwd, "bbbbbbbb-2222-4222-8222-222222222222", &claude.log);

    let outcome = bind(
        &facts(
            "claude",
            Some(&cwd),
            Some((claude.prompt.as_str(), claude.submitted_ms)),
        ),
        &home.roots(),
    );
    assert_eq!(
        outcome,
        Binding::Ambiguous {
            candidates: vec![a.clone(), b.clone()],
            undecided: Vec::new(),
        },
        "same cwd + same prompt refuses, listing both in path order"
    );

    // No prompt at all: cwd and time alone never tie a file to a terminal.
    assert_eq!(
        bind(&facts("claude", Some(&cwd), None), &home.roots()),
        Binding::NoLog,
        "without prompt evidence nothing binds"
    );

    // Codex: two rollouts, same cwd and originator, same prompt, same day.
    let codex_home = Home::new("ambiguous-codex");
    let mut bytes =
        codex_meta_line(CODEX_SPIKE_CWD, "codex-tui", "2026-09-19T01:19:17.900Z").into_bytes();
    bytes.extend_from_slice(&codex.log);
    let first = codex_home.codex_log(
        "rollout-2026-09-18T18-18-15-01a0b73e-19ab-7402-9459-3cdd9e73a816.jsonl",
        &bytes,
    );
    let second = codex_home.codex_log(
        "rollout-2026-09-18T18-19-15-01a0b73e-19ab-7402-9459-3cdd9e73a817.jsonl",
        &bytes,
    );
    assert_eq!(
        bind(
            &facts(
                "codex",
                Some(CODEX_SPIKE_CWD),
                Some((codex.prompt.as_str(), codex.submitted_ms))
            ),
            &codex_home.roots()
        ),
        Binding::Ambiguous {
            candidates: vec![first, second],
            undecided: Vec::new(),
        },
        "two codex rollouts with identical evidence refuse"
    );
}

/// Wrong directory, wrong originator or a window the session never overlapped:
/// each must yield no log rather than the nearest file.
#[test]
fn mismatched_evidence_never_binds() {
    let pairs = load_pairs();
    let claude = pairs
        .iter()
        .find(|p| p.harness == "claude" && p.has_log())
        .unwrap();
    let codex = pairs
        .iter()
        .find(|p| p.harness == "codex" && p.has_log())
        .unwrap();
    let cwd = claude.recorded_cwd.clone().unwrap();
    let other_cwd = "/Users/nobody/elsewhere";

    let home = Home::new("mismatch");
    home.claude_log(&cwd, "cccccccc-3333-4333-8333-333333333333", &claude.log);
    assert_eq!(
        bind(
            &facts(
                "claude",
                Some(other_cwd),
                Some((claude.prompt.as_str(), claude.submitted_ms))
            ),
            &home.roots()
        ),
        Binding::NoLog,
        "a different cwd looks in a different project directory"
    );

    // Slug collision: "/…/else where" and "/…/else-where" share one project
    // directory. The per-record cwd check is what saves this case.
    let collided = Home::new("collision");
    let spaced = "/Users/nobody/else where";
    let hyphened = "/Users/nobody/else-where";
    let both = collided.claude_log(spaced, "dddddddd-4444-4444-8444-444444444444", &claude.log);
    assert!(
        both.starts_with(
            collided
                .0
                .join(".claude/projects")
                .join(session_log::claude_project_slug(Path::new(hyphened)))
        ),
        "the two cwds really do share a project directory"
    );
    assert_eq!(
        bind(
            &facts(
                "claude",
                Some(hyphened),
                Some((claude.prompt.as_str(), claude.submitted_ms))
            ),
            &collided.roots()
        ),
        Binding::NoLog,
        "records naming another cwd are rejected even inside a matching slug"
    );

    // Codex: same cwd and prompt, but written by `codex exec`, not the TUI.
    let exec_home = Home::new("codex-exec");
    let mut bytes =
        codex_meta_line(CODEX_SPIKE_CWD, "codex_exec", "2026-09-19T01:19:17.900Z").into_bytes();
    bytes.extend_from_slice(&codex.log);
    exec_home.codex_log(
        "rollout-2026-09-18T18-07-42-01a0b734-6f3e-77b1-adb2-daf1b5d42c7b.jsonl",
        &bytes,
    );
    assert_eq!(
        bind(
            &facts(
                "codex",
                Some(CODEX_SPIKE_CWD),
                Some((codex.prompt.as_str(), codex.submitted_ms))
            ),
            &exec_home.roots()
        ),
        Binding::NoLog,
        "a non-interactive rollout is not a watched terminal's log"
    );

    // Windows the recorded turn cannot belong to (2020-01-01 and 2030-01-01).
    let good = Home::new("window");
    good.claude_log(&cwd, "eeeeeeee-5555-4555-8555-555555555555", &claude.log);
    for (start, end, label) in [
        (1_577_836_800_000_i64, Some(1_577_923_200_000_i64), "before"),
        (1_893_456_000_000_i64, None, "after"),
    ] {
        let mut f = facts(
            "claude",
            Some(&cwd),
            Some((claude.prompt.as_str(), claude.submitted_ms)),
        );
        f.window_start_ms = start;
        f.window_end_ms = end;
        assert_eq!(
            bind(&f, &good.roots()),
            Binding::NoLog,
            "a window {label} the session is not its window"
        );
    }
}

/// The log formats are unstable: junk lines, unknown record types and invalid
/// UTF-8 must be stepped over, and a file that carries no usable record at all
/// is simply not a log. An unknown profile is refused outright.
#[test]
fn unknown_shapes_are_never_fatal() {
    let pairs = load_pairs();
    let claude = pairs
        .iter()
        .find(|p| p.harness == "claude" && p.has_log())
        .unwrap();
    let cwd = claude.recorded_cwd.clone().unwrap();

    let home = Home::new("junk");
    let mut noisy: Vec<u8> = Vec::new();
    noisy.extend_from_slice(b"not json at all\n");
    noisy.extend_from_slice(
        b"{\"type\": \"future-record\", \"fields\": {\"we\": \"cannot know\"}}\n",
    );
    noisy.extend_from_slice(b"[1, 2, 3]\n");
    noisy.extend_from_slice(&[0xff, 0xfe, 0x00, b'\n']);
    noisy.extend_from_slice(b"\n");
    noisy.extend_from_slice(&claude.log);
    noisy.extend_from_slice(b"{\"type\": \"user\", \"message\": {\"content\": 42}}\n");
    noisy.extend_from_slice(b"{\"truncated\": \n");
    let path = home.claude_log(&cwd, "ffffffff-6666-4666-8666-666666666666", &noisy);
    assert_eq!(
        bind(
            &facts(
                "claude",
                Some(&cwd),
                Some((claude.prompt.as_str(), claude.submitted_ms))
            ),
            &home.roots()
        ),
        Binding::Bound(path),
        "records survive the junk around them"
    );

    // A file of unknown records only: no timestamp, so no evidence.
    let blind = Home::new("blind");
    blind.claude_log(
        &cwd,
        "99999999-7777-4777-8777-777777777777",
        b"{\"type\": \"future-record\"}\n{\"type\": \"another\"}\n",
    );
    assert_eq!(
        bind(
            &facts(
                "claude",
                Some(&cwd),
                Some((claude.prompt.as_str(), claude.submitted_ms))
            ),
            &blind.roots()
        ),
        Binding::NoLog,
        "records without a timestamp bind nothing"
    );

    // Nothing on disk at all, and a profile with no known layout.
    let empty = Home::new("empty");
    assert_eq!(
        bind(
            &facts("claude", Some(&cwd), Some(("anything", 1_700_000_000_000))),
            &empty.roots()
        ),
        Binding::NoLog,
        "an absent log tree reports no log, not an error"
    );
    assert_eq!(
        bind(
            &facts(
                "opencode",
                Some(&cwd),
                Some(("anything", 1_700_000_000_000))
            ),
            &empty.roots()
        ),
        Binding::Unsupported("opencode".to_string()),
        "a profile with no known log layout is refused explicitly"
    );
}

/// The relay may restart while the terminal keeps running. Nothing is
/// remembered, so re-deriving from the same facts must give the same file.
#[test]
fn binding_survives_a_relay_restart() {
    let pairs = load_pairs();
    let claude = pairs
        .iter()
        .find(|p| p.harness == "claude" && p.has_log())
        .unwrap();
    let codex = pairs
        .iter()
        .find(|p| p.harness == "codex" && p.has_log())
        .unwrap();
    let cwd = claude.recorded_cwd.clone().unwrap();

    let home = Home::new("restart");
    let claude_path = home.claude_log(&cwd, "12121212-8888-4888-8888-888888888888", &claude.log);
    let codex_path = home.codex_log(&codex.log_name, &codex.log);

    for _ in 0..2 {
        // Fresh facts and roots each round: the same inputs a restarted relay
        // would rebuild from its persisted watch registry.
        assert_eq!(
            bind(
                &facts(
                    "claude",
                    Some(&cwd),
                    Some((claude.prompt.as_str(), claude.submitted_ms))
                ),
                &home.roots()
            ),
            Binding::Bound(claude_path.clone()),
        );
        assert_eq!(
            bind(
                &facts(
                    "codex",
                    None,
                    Some((codex.prompt.as_str(), codex.submitted_ms))
                ),
                &home.roots()
            ),
            Binding::Bound(codex_path.clone()),
        );
    }
}

// ---------------------------------------------------------------------------
// Bounded reads
// ---------------------------------------------------------------------------

/// A claude user record, the shape the head scan and the prompt check both read.
fn claude_user_line(cwd: &str, timestamp: &str, text: &str) -> String {
    serde_json::json!({
        "type": "user",
        "cwd": cwd,
        "timestamp": timestamp,
        "message": {"role": "user", "content": text},
    })
    .to_string()
        + "\n"
}

/// At least `bytes` of records that carry no evidence, so that only their size
/// matters to the reads under test.
fn filler_lines(cwd: &str, timestamp: &str, bytes: usize) -> String {
    let line = serde_json::json!({
        "type": "system",
        "subtype": "filler",
        "cwd": cwd,
        "timestamp": timestamp,
        "filler": "x".repeat(4_096),
    })
    .to_string()
        + "\n";
    line.repeat(bytes / line.len() + 1)
}

/// At least `bytes` of lines that are not JSON at all, which yield no records
/// and so are bounded by nothing but the head scan's byte budget.
fn junk_lines(bytes: usize) -> String {
    let line = format!("{}\n", "not json ".repeat(64));
    line.repeat(bytes / line.len() + 1)
}

fn set_mtime_ms(path: &Path, ms: u64) {
    let file = fs::File::options().write(true).open(path).expect("open");
    let times = fs::FileTimes::new()
        .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_millis(ms));
    file.set_times(times).expect("set mtime");
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// The pruning pass reads a bounded number of RECORDS, which bounds nothing on
/// a file of unparseable lines: those yield no records at all. A head of junk
/// larger than the byte budget must end the scan, leaving the file with no
/// readable evidence and so out of the search — even though the evidence that
/// would have matched is sitting just past the budget.
#[test]
fn a_head_of_unparseable_lines_is_bounded_by_bytes() {
    const CWD: &str = "/work/junk-head-proj";
    const TS: &str = "2026-09-19T01:00:00.000Z";
    const PROMPT: &str = "bind me";
    let records = claude_user_line(CWD, TS, PROMPT);

    let short = Home::new("junk-head-short");
    let readable = short.claude_log(
        CWD,
        "short",
        format!("{}{records}", junk_lines(8 * 1024)).as_bytes(),
    );
    assert_eq!(
        bind(
            &facts("claude", Some(CWD), Some((PROMPT, at(TS)))),
            &short.roots()
        ),
        Binding::Bound(readable),
        "junk inside the budget is stepped over and the records behind it read"
    );

    let long = Home::new("junk-head-long");
    long.claude_log(
        CWD,
        "long",
        format!(
            "{}{records}",
            junk_lines(session_log::HEAD_SCAN_BYTES as usize + 64 * 1024)
        )
        .as_bytes(),
    );
    assert_eq!(
        bind(
            &facts("claude", Some(CWD), Some((PROMPT, at(TS)))),
            &long.roots()
        ),
        Binding::NoLog,
        "past the byte budget the scan stops, so the same records are never reached"
    );
}

/// The one rule, put to the three layouts it has to get right: two transcripts
/// that both hold the current prompt inside its submit window are refused; a
/// harness `/clear` that left our own log new and small beside a sibling with a
/// long history is refused the same way, never bound to the sibling; and a
/// sibling holding the prompt TEXT stamped outside the window is no candidate
/// at all. A prompt with no known submit instant has no window, so it binds
/// nothing.
#[test]
fn only_the_current_prompt_inside_its_submit_window_makes_a_candidate() {
    const CWD: &str = "/work/one-rule-proj";
    const OLD: &str = "set up the fixture";
    const CURRENT: &str = "continue";
    const OLD_TS: &str = "2026-09-19T00:45:00.000Z";
    const CURRENT_TS: &str = "2026-09-19T01:00:00.000Z";
    /// The same text sent again a minute later: one prompt, another turn.
    const REPEAT_TS: &str = "2026-09-19T01:01:00.000Z";
    let submitted_ms = at(CURRENT_TS);
    let current_line = claude_user_line(CWD, CURRENT_TS, CURRENT);

    let both = Home::new("one-rule-both");
    let both_ours = both.claude_log(CWD, "aaaa-ours", current_line.as_bytes());
    let both_sibling = both.claude_log(CWD, "bbbb-sibling", current_line.as_bytes());
    assert_eq!(
        bind(
            &facts("claude", Some(CWD), Some((CURRENT, submitted_ms))),
            &both.roots()
        ),
        Binding::Ambiguous {
            candidates: vec![both_ours, both_sibling],
            undecided: Vec::new(),
        },
        "two terminals holding one prompt in one window are the documented limit"
    );

    // After a `/clear`: our log is new and holds nothing but the current
    // prompt, while the sibling kept a history longer than the prompt window
    // and received the same prompt inside it.
    let cleared = Home::new("one-rule-cleared");
    let cleared_ours = cleared.claude_log(CWD, "aaaa-ours", current_line.as_bytes());
    let cleared_sibling = cleared.claude_log(
        CWD,
        "bbbb-sibling",
        format!(
            "{}{}{current_line}",
            claude_user_line(CWD, OLD_TS, OLD),
            filler_lines(
                CWD,
                OLD_TS,
                session_log::PROMPT_SCAN_BYTES as usize + 64 * 1024
            ),
        )
        .as_bytes(),
    );
    assert_eq!(
        bind(
            &facts("claude", Some(CWD), Some((CURRENT, submitted_ms))),
            &cleared.roots()
        ),
        Binding::Ambiguous {
            candidates: vec![cleared_ours, cleared_sibling],
            undecided: Vec::new(),
        },
        "the sibling's history is no evidence: it is refused beside ours, never bound"
    );

    // A sibling that holds the prompt text from another turn.
    let apart = Home::new("one-rule-apart");
    let apart_ours = apart.claude_log(CWD, "aaaa-ours", current_line.as_bytes());
    apart.claude_log(
        CWD,
        "bbbb-sibling",
        claude_user_line(CWD, REPEAT_TS, CURRENT).as_bytes(),
    );
    assert_eq!(
        bind(
            &facts("claude", Some(CWD), Some((CURRENT, submitted_ms))),
            &apart.roots()
        ),
        Binding::Bound(apart_ours),
        "a stamp outside the submit window belongs to another turn"
    );

    // A prompt restored from a state file written before submit times existed.
    assert_eq!(
        bind(
            &facts("claude", Some(CWD), Some((CURRENT, 0))),
            &apart.roots()
        ),
        Binding::NoLog,
        "no submit instant is no window, and no window admits no candidate"
    );
}

/// The everyday two-tab layout: a sibling in the same project directory that
/// never received the current prompt, laid out both larger and smaller than the
/// prompt window, and stamped both before and after our own records. The
/// sibling's stamps decide nothing, and its size decides nothing either: the
/// idle tab's last write precedes the submit, so a window larger than the
/// prompt window is ruled out on the same evidence as a small one, and our
/// transcript binds every time.
#[test]
fn a_sibling_lacking_the_current_prompt_is_ruled_out_at_any_size() {
    const CWD: &str = "/work/two-tab-proj";
    const PROMPT: &str = "continue";
    const EARLY_TS: &str = "2026-09-19T00:00:00.000Z";
    const LATE_TS: &str = "2026-09-19T02:00:00.000Z";
    const OURS_TS: &str = "2026-09-19T01:30:00.000Z";
    let window_start_ms = at("2026-09-19T01:00:00.000Z");
    let ours_bytes = claude_user_line(CWD, OURS_TS, PROMPT);
    let over_window = session_log::PROMPT_SCAN_BYTES as usize + 64 * 1024;

    // The whole layout is stamped inside the alive window, the sibling by the
    // one late write that parks an idle tab's mtime there for good.
    let alive_ms = (window_start_ms + 60_000) as u64;

    for (label, sibling_ts, size) in [
        ("large-early", EARLY_TS, over_window),
        ("large-late", LATE_TS, over_window),
        ("small", OURS_TS, 8 * 1024),
    ] {
        let home = Home::new(&format!("two-tab-{label}"));
        let ours = home.claude_log(CWD, "aaaa-ours", ours_bytes.as_bytes());
        let sibling = home.claude_log(
            CWD,
            "bbbb-sibling",
            filler_lines(CWD, sibling_ts, size).as_bytes(),
        );
        set_mtime_ms(&ours, alive_ms);
        set_mtime_ms(&sibling, alive_ms);

        let mut f = facts("claude", Some(CWD), Some((PROMPT, at(OURS_TS))));
        f.window_start_ms = window_start_ms;
        assert_eq!(
            bind(&f, &home.roots()),
            Binding::Bound(ours),
            "{label}: a transcript without the current prompt is no candidate"
        );
    }
}

/// An unrelated transcript larger than the prompt window, left behind in the
/// same project directory by a session that ended before this terminal started.
/// The pruning pass drops it on the alive window, so it never reaches the
/// prompt check and never leaves the search undecided.
#[test]
fn a_transcript_pruned_before_the_prompt_check_does_not_make_the_search_undecided() {
    const CWD: &str = "/work/stale-proj";
    const PROMPT: &str = "continue";
    const STALE_TS: &str = "2020-01-01T00:00:00.000Z";
    const OURS_TS: &str = "2026-09-19T01:00:00.000Z";
    let start_ms = now_ms();

    let home = Home::new("stale-large");
    let stale = home.claude_log(
        CWD,
        "aaaa-stale",
        format!(
            "{}{}",
            claude_user_line(CWD, STALE_TS, "an older session"),
            filler_lines(
                CWD,
                STALE_TS,
                session_log::PROMPT_SCAN_BYTES as usize + 64 * 1024
            ),
        )
        .as_bytes(),
    );
    set_mtime_ms(&stale, (start_ms - 3_600_000) as u64);
    let ours = home.claude_log(
        CWD,
        "bbbb-ours",
        claude_user_line(CWD, OURS_TS, PROMPT).as_bytes(),
    );

    let mut f = facts("claude", Some(CWD), Some((PROMPT, at(OURS_TS))));
    f.window_start_ms = start_ms;
    assert_eq!(
        bind(&f, &home.roots()),
        Binding::Bound(ours),
        "a transcript whose last write precedes the terminal binds nothing"
    );
}

/// A claude user record padded out to exactly `total` bytes, newline included.
/// The padding sits in a field nothing reads, so two of these differ only in
/// size.
fn padded_claude_user_line(cwd: &str, timestamp: &str, text: &str, total: usize) -> String {
    let build = |pad: usize| {
        serde_json::json!({
            "type": "user",
            "cwd": cwd,
            "timestamp": timestamp,
            "pad": "x".repeat(pad),
            "message": {"role": "user", "content": text},
        })
        .to_string()
            + "\n"
    };
    let bare = build(0).len();
    let line = build(total.saturating_sub(bare));
    assert_eq!(line.len(), total, "padding lands on the wanted size");
    line
}

/// The head budget bounds the READER, not a tally taken before each line: a
/// single record longer than the budget must never be read, let alone parsed.
/// The two files below hold the same record either side of the budget, so the
/// oversized one binding would itself be the proof that the read ran past it.
#[test]
fn one_record_longer_than_the_head_budget_is_never_read() {
    const CWD: &str = "/work/giant-record-proj";
    const TS: &str = "2026-09-19T01:00:00.000Z";
    const PROMPT: &str = "bind me";
    let budget = session_log::HEAD_SCAN_BYTES as usize;

    let inside = Home::new("giant-inside");
    let readable = inside.claude_log(
        CWD,
        "inside",
        padded_claude_user_line(CWD, TS, PROMPT, budget - 1).as_bytes(),
    );
    assert_eq!(
        bind(
            &facts("claude", Some(CWD), Some((PROMPT, at(TS)))),
            &inside.roots()
        ),
        Binding::Bound(readable),
        "a record that fits in the budget is read whole"
    );

    let over = Home::new("giant-over");
    over.claude_log(
        CWD,
        "over",
        padded_claude_user_line(CWD, TS, PROMPT, budget + 1).as_bytes(),
    );
    assert_eq!(
        bind(
            &facts("claude", Some(CWD), Some((PROMPT, at(TS)))),
            &over.roots()
        ),
        Binding::NoLog,
        "one byte past the budget the record is cut, so it is never parsed"
    );
}

/// Back-dated records are lower bounds on write time, so the stamps in a tail
/// window cannot say when the bytes ahead of it were written. Here our own log
/// wrote the current prompt and then more back-dated filler than the window
/// holds, which pushed that prompt out: our log was written after the submit,
/// so nothing about it is established and it stays undecided, while a sibling
/// that never received the current prompt is no candidate. The outcome is a
/// refusal and the screen text — never the sibling's transcript.
#[test]
fn back_dated_filler_past_the_window_never_binds_a_sibling() {
    const CWD: &str = "/work/out-of-order-proj";
    const EARLY: &str = "set up the fixture";
    const CURRENT: &str = "continue";
    const FILLER_TS: &str = "2026-09-19T00:50:00.000Z";
    const EARLY_TS: &str = "2026-09-19T00:45:00.000Z";
    const CURRENT_TS: &str = "2026-09-19T00:55:00.000Z";
    // The terminal was created between the filler's stamp and the prompt's.
    let window_start_ms = at("2026-09-19T00:52:00.000Z");

    // The filler is written AFTER the current prompt and stamped before it.
    let ours_bytes = format!(
        "{}{}{}",
        claude_user_line(CWD, EARLY_TS, EARLY),
        claude_user_line(CWD, CURRENT_TS, CURRENT),
        filler_lines(
            CWD,
            FILLER_TS,
            session_log::PROMPT_SCAN_BYTES as usize + 64 * 1024
        ),
    );
    // The sibling holds the older prompt only: it never received the current one.
    let sibling_bytes = claude_user_line(CWD, EARLY_TS, EARLY);

    let home = Home::new("out-of-order");
    let ours = home.claude_log(CWD, "aaaa-ours", ours_bytes.as_bytes());
    home.claude_log(CWD, "bbbb-sibling", sibling_bytes.as_bytes());
    // The filler was written after the submit, whatever it is stamped.
    set_mtime_ms(&ours, (at(CURRENT_TS) + 30_000) as u64);

    let mut f = facts("claude", Some(CWD), Some((CURRENT, at(CURRENT_TS))));
    f.window_start_ms = window_start_ms;
    assert_eq!(
        bind(&f, &home.roots()),
        Binding::Ambiguous {
            candidates: vec![ours.clone()],
            undecided: vec![ours],
        },
        "a log that outgrew its window since the current prompt hands nothing \
         to a sibling that never held it"
    );
}

/// Every read the prompt check makes is bounded by a length its caller captured
/// before the read, so records a harness appends while the check runs are never
/// parsed: the same file judged against the grown length is what shows the
/// appended record is otherwise plainly visible.
#[test]
fn the_prompt_check_reads_only_what_its_captured_length_names() {
    const CWD: &str = "/work/growing-proj";
    const CURRENT: &str = "continue";
    const TS: &str = "2026-09-19T01:00:00.000Z";
    let home = Home::new("growing");
    let f = facts("claude", Some(CWD), Some((CURRENT, at(TS))));

    for (label, head) in [
        ("whole file", filler_lines(CWD, TS, 8 * 1024)),
        (
            "truncated",
            filler_lines(CWD, TS, session_log::PROMPT_SCAN_BYTES as usize + 64 * 1024),
        ),
    ] {
        let path = home.claude_log(
            CWD,
            &format!("{}-log", label.replace(' ', "-")),
            head.as_bytes(),
        );
        let captured = fs::metadata(&path).unwrap().len();
        // The append a concurrent harness would make between the capture and
        // the read.
        fs::write(
            &path,
            format!("{head}{}", claude_user_line(CWD, TS, CURRENT)).as_bytes(),
        )
        .unwrap();
        let grown = fs::metadata(&path).unwrap().len();
        // A truncated window lacking the prompt is judged on the file's last
        // write; dated before the submit, it is what the read found that
        // decides, which is the whole of what is under test here.
        set_mtime_ms(&path, (at(TS) - 60_000) as u64);

        assert!(
            session_log::tail_offset_within(&path, session_log::PROMPT_SCAN_BYTES, captured)
                <= captured,
            "{label}: the window never opens past the captured length"
        );
        assert_eq!(
            session_log::prompt_evidence(&path, session_log::Harness::Claude, &f, captured),
            session_log::PromptEvidence::Lacks,
            "{label}: bytes past the captured length are not parsed"
        );
        assert_eq!(
            session_log::prompt_evidence(&path, session_log::Harness::Claude, &f, grown),
            session_log::PromptEvidence::Holds,
            "{label}: the same record is found once the length covers it"
        );
    }
}

/// The search for the record boundary at a tail window's edge is bounded too. A
/// record longer than TAIL_BOUNDARY_BYTES straddling that edge yields no
/// boundary, and the conservative answer is the captured length itself: a
/// window that reads nothing, never one opening mid-record.
#[test]
fn a_record_longer_than_the_boundary_bound_yields_no_boundary() {
    const CWD: &str = "/work/boundary-proj";
    const TS: &str = "2026-09-19T01:00:00.000Z";
    let bound = session_log::TAIL_BOUNDARY_BYTES as usize;
    let long = padded_claude_user_line(CWD, TS, "bind me", bound + 64 * 1024);
    let short = claude_user_line(CWD, TS, "and again");

    let home = Home::new("boundary");
    let path = home.claude_log(CWD, "long-record", format!("{long}{short}").as_bytes());
    let len = (long.len() + short.len()) as u64;

    assert_eq!(
        session_log::tail_offset_within(&path, (bound + 32 * 1024) as u64, len),
        len,
        "no newline inside the bound is no boundary, so the window yields nothing"
    );
    assert_eq!(
        session_log::tail_offset_within(&path, (short.len() + 1_024) as u64, len),
        long.len() as u64,
        "a boundary inside the bound is where the whole records begin"
    );
    assert_eq!(
        session_log::tail_offset_within(&home.0.join("no-such-file.jsonl"), 1_024, len),
        len,
        "a file that cannot even be opened yields an empty window, not the whole file"
    );
}

/// A truncated window whose edge falls inside one record longer than the
/// boundary bound yields no record, and an unread window is no evidence: the
/// candidate stays undecided rather than ruled out for its contents, and one
/// undecided candidate keeps the whole search ambiguous — it is reported there
/// by name, so the caller can see the search was refused and not decided.
#[test]
fn an_unread_truncated_window_leaves_the_search_ambiguous() {
    const CWD: &str = "/work/unread-window-proj";
    const TS: &str = "2026-09-19T01:00:00.000Z";
    const CURRENT: &str = "the current prompt";
    let huge = session_log::PROMPT_SCAN_BYTES as usize
        + session_log::TAIL_BOUNDARY_BYTES as usize
        + 64 * 1024;
    let long = padded_claude_user_line(CWD, TS, "an old prompt", huge);
    let short = claude_user_line(CWD, TS, CURRENT);
    // One small record ahead of the huge one, so the head scan still finds the
    // cwd and stamp it prunes by: what is under test is the TAIL window.
    let head = claude_user_line(CWD, TS, "an older prompt still");

    let home = Home::new("unread-window");
    let unread = home.claude_log(
        CWD,
        "bbbb-huge-record",
        format!("{head}{long}{short}").as_bytes(),
    );
    let len = (head.len() + long.len() + short.len()) as u64;
    let terminal = facts("claude", Some(CWD), Some((CURRENT, at(TS))));

    assert_eq!(
        session_log::prompt_evidence(&unread, session_log::Harness::Claude, &terminal, len),
        session_log::PromptEvidence::Undecided,
        "a window the boundary bound could not open was never read"
    );

    let ours = home.claude_log(CWD, "aaaa-ours", short.as_bytes());
    assert_eq!(
        bind(&terminal, &home.roots()),
        Binding::Ambiguous {
            candidates: vec![ours, unread.clone()],
            undecided: vec![unread],
        },
        "an unread window cannot make its neighbour a unique match"
    );

    // A prompt restored from a state file written before submit times existed:
    // settled before any window is opened, so an unreadable one cannot turn it
    // into a refusal.
    assert_eq!(
        bind(
            &facts("claude", Some(CWD), Some((CURRENT, 0))),
            &home.roots()
        ),
        Binding::NoLog,
        "no submit instant is no log, whatever the windows would have read"
    );
}
