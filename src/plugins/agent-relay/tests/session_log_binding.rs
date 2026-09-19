// session_log_binding.rs — does the binder find the right harness log?
//
// The corpus at tests/fixtures/loss_pairs holds eleven real turns with the
// session-log records the harness wrote for each (an empty session_log.jsonl
// means it wrote none). Every test below lays those real bytes out in a temp
// directory in the harness's own shape and asks the binder to find them again
// from nothing but profile, cwd, alive-window and the prompts that were sent.
//
// The crate is a binary, so the module is pulled in by path, as the other
// test files do.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::Value;

#[path = "../src/session_log.rs"]
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
            pairs.push(Pair {
                harness: harness.to_string(),
                name: dir.file_name().unwrap().to_string_lossy().into_owned(),
                log,
                prompt,
                log_name: meta["session_log"].as_str().unwrap().to_string(),
                recorded_cwd,
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

fn facts(profile: &str, cwd: Option<&str>, prompts: &[&str]) -> TerminalFacts {
    TerminalFacts {
        profile_id: profile.to_string(),
        cwd: cwd.map(PathBuf::from),
        window_start_ms: 0,
        window_end_ms: None,
        prompts: prompts.iter().map(|p| p.to_string()).collect(),
    }
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
            &facts(&pair.harness, cwd, &[pair.prompt.as_str()]),
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
        &facts("claude", Some(&cwd), &[claude.prompt.as_str()]),
        &home.roots(),
    );
    assert_eq!(
        outcome,
        Binding::Ambiguous(vec![a.clone(), b.clone()]),
        "same cwd + same prompt refuses, listing both in path order"
    );

    // No prompts at all: cwd and time alone never separate two live sessions.
    assert_eq!(
        bind(&facts("claude", Some(&cwd), &[]), &home.roots()),
        Binding::Ambiguous(vec![a, b]),
        "without prompt evidence the pair stays ambiguous"
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
            &facts("codex", Some(CODEX_SPIKE_CWD), &[codex.prompt.as_str()]),
            &codex_home.roots()
        ),
        Binding::Ambiguous(vec![first, second]),
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
            &facts("claude", Some(other_cwd), &[claude.prompt.as_str()]),
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
            &facts("claude", Some(hyphened), &[claude.prompt.as_str()]),
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
            &facts("codex", Some(CODEX_SPIKE_CWD), &[codex.prompt.as_str()]),
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
        let mut f = facts("claude", Some(&cwd), &[claude.prompt.as_str()]);
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
            &facts("claude", Some(&cwd), &[claude.prompt.as_str()]),
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
            &facts("claude", Some(&cwd), &[claude.prompt.as_str()]),
            &blind.roots()
        ),
        Binding::NoLog,
        "records without a timestamp bind nothing"
    );

    // Nothing on disk at all, and a profile with no known layout.
    let empty = Home::new("empty");
    assert_eq!(
        bind(&facts("claude", Some(&cwd), &["anything"]), &empty.roots()),
        Binding::NoLog,
        "an absent log tree reports no log, not an error"
    );
    assert_eq!(
        bind(
            &facts("opencode", Some(&cwd), &["anything"]),
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
                &facts("claude", Some(&cwd), &[claude.prompt.as_str()]),
                &home.roots()
            ),
            Binding::Bound(claude_path.clone()),
        );
        assert_eq!(
            bind(
                &facts("codex", None, &[codex.prompt.as_str()]),
                &home.roots()
            ),
            Binding::Bound(codex_path.clone()),
        );
    }
}
