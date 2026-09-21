// session_log_evidence.rs — what a transcript larger than the prompt window
// proves when that window does not hold the current prompt.
//
// The fast window is the last PROMPT_SCAN_BYTES of a file. An active candidate
// whose prompt may sit ahead of it is then read completely under the aggregate
// fallback budget; only a complete valid snapshot can prove absence.
//
// The crate is a binary, so the module is pulled in by path, as the other test
// files do.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

#[path = "../src/session_log.rs"]
#[allow(dead_code)]
mod session_log;

use session_log::{bind, Binding, LogRoots, TerminalFacts};

const CWD: &str = "/work/evidence-proj";
const PROMPT: &str = "continue";
const TS: &str = "2026-09-19T01:00:00.000Z";

// ---------------------------------------------------------------------------
// Layout construction
// ---------------------------------------------------------------------------

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A throwaway home holding one claude project directory.
struct Home(PathBuf);

impl Home {
    fn new(tag: &str) -> Home {
        let path = std::env::temp_dir().join(format!(
            "agent-relay-evidence-{}-{}-{}",
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

    fn claude_log(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let dir = self
            .0
            .join(".claude/projects")
            .join(session_log::claude_project_slug(Path::new(CWD)));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("{name}.jsonl"));
        fs::write(&path, bytes).unwrap();
        path
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// A claude user record, the shape the prompt check reads.
fn claude_user_line(timestamp: &str, text: &str) -> String {
    serde_json::json!({
        "type": "user",
        "cwd": CWD,
        "timestamp": timestamp,
        "message": {"role": "user", "content": text},
    })
    .to_string()
        + "\n"
}

/// More ordinary records than the prompt window holds, carrying no evidence:
/// only their size matters here.
fn past_the_window(timestamp: &str) -> String {
    let line = serde_json::json!({
        "type": "system",
        "subtype": "filler",
        "cwd": CWD,
        "timestamp": timestamp,
        "filler": "x".repeat(4_096),
    })
    .to_string()
        + "\n";
    let bytes = 32 * 1024 * 1024;
    line.repeat(bytes / line.len() + 1)
}

fn set_mtime_ms(path: &Path, ms: i64) {
    let file = fs::File::options().write(true).open(path).expect("open");
    let times = fs::FileTimes::new()
        .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_millis(ms as u64));
    file.set_times(times).expect("set mtime");
}

/// Binder input for a terminal whose current prompt is PROMPT, submitted at TS.
fn facts() -> TerminalFacts {
    TerminalFacts {
        profile_id: "claude".to_string(),
        cwd: Some(PathBuf::from(CWD)),
        window_start_ms: 0,
        window_end_ms: None,
        current_prompt: Some(PROMPT.to_string()),
        current_submitted_ms: session_log::parse_iso_ms(TS).expect("readable stamp"),
    }
}

fn submitted_ms() -> i64 {
    session_log::parse_iso_ms(TS).expect("readable stamp")
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Both terminals received the prompt inside its window, and ours then wrote
/// more than the fast window holds. The complete fallback finds the hidden
/// prompt, so both candidates remain confirmed rather than one being selected.
#[test]
fn a_log_written_past_its_window_since_the_submit_stays_undecided() {
    let home = Home::new("outgrown");
    let ours = home.claude_log(
        "aaaa-ours",
        format!("{}{}", claude_user_line(TS, PROMPT), past_the_window(TS)).as_bytes(),
    );
    let sibling = home.claude_log("bbbb-sibling", claude_user_line(TS, PROMPT).as_bytes());
    set_mtime_ms(&ours, submitted_ms() + 30_000);
    set_mtime_ms(&sibling, submitted_ms() + 1_000);

    assert_eq!(
        bind(&facts(), &home.roots()),
        Binding::Ambiguous {
            candidates: vec![ours.clone(), sibling],
            undecided: Vec::new(),
        },
        "a prompt hidden before the tail still prevents a sibling bind"
    );
}

/// The idle neighbouring tab: a transcript larger than the prompt window that
/// never received the current prompt. A complete valid snapshot rules it out
/// whether its last write is before or after the submit.
#[test]
fn an_idle_sibling_larger_than_the_window_is_ruled_out_by_its_last_write() {
    let home = Home::new("idle-sibling");
    let ours = home.claude_log("aaaa-ours", claude_user_line(TS, PROMPT).as_bytes());
    let sibling = home.claude_log(
        "bbbb-sibling",
        past_the_window("2026-09-19T00:30:00.000Z").as_bytes(),
    );
    set_mtime_ms(&ours, submitted_ms() + 1_000);
    set_mtime_ms(&sibling, submitted_ms() - 60_000);

    assert_eq!(
        bind(&facts(), &home.roots()),
        Binding::Bound(ours.clone()),
        "a file that took no write after the submit cannot hold the prompt"
    );

    set_mtime_ms(&sibling, submitted_ms() + 30_000);
    assert_eq!(
        bind(&facts(), &home.roots()),
        Binding::Bound(ours),
        "the complete active sibling snapshot proves the prompt absent"
    );
}

#[test]
fn malformed_and_over_budget_fallbacks_remain_undecided() {
    let home = Home::new("fallback-guards");
    let ours = home.claude_log("aaaa-ours", claude_user_line(TS, PROMPT).as_bytes());
    let malformed = home.claude_log(
        "bbbb-malformed",
        format!(
            "{}{{not-json}}\n{}",
            claude_user_line(TS, "sibling prompt"),
            past_the_window(TS)
        )
        .as_bytes(),
    );
    set_mtime_ms(&malformed, submitted_ms() + 30_000);
    assert_eq!(
        bind(&facts(), &home.roots()),
        Binding::Ambiguous {
            candidates: vec![ours.clone(), malformed.clone()],
            undecided: vec![malformed],
        },
        "malformed full snapshots cannot prove prompt absence"
    );

    let dir = ours.parent().unwrap();
    fs::remove_file(dir.join("bbbb-malformed.jsonl")).unwrap();
    let over = dir.join("bbbb-over-budget.jsonl");
    fs::write(&over, claude_user_line(TS, "sibling prompt")).unwrap();
    fs::OpenOptions::new()
        .write(true)
        .open(&over)
        .unwrap()
        .set_len(session_log::FULL_SCAN_BUDGET_BYTES + 1)
        .unwrap();
    assert_eq!(
        bind(&facts(), &home.roots()),
        Binding::Ambiguous {
            candidates: vec![ours, over.clone()],
            undecided: vec![over],
        },
        "the aggregate full-scan budget fails closed"
    );
}

#[test]
fn complete_fallback_budget_is_shared_across_candidates() {
    let home = Home::new("aggregate-budget");
    let ours = home.claude_log("aaaa-ours", claude_user_line(TS, PROMPT).as_bytes());
    let dir = ours.parent().unwrap();
    let first = dir.join("bbbb-first.jsonl");
    fs::write(&first, claude_user_line(TS, "sibling prompt")).unwrap();
    fs::OpenOptions::new()
        .write(true)
        .open(&first)
        .unwrap()
        .set_len(40 * 1024 * 1024)
        .unwrap();
    let second = dir.join("cccc-second.jsonl");
    fs::write(&second, past_the_window(TS)).unwrap();
    let unresolved = vec![first, second];
    assert_eq!(
        bind(&facts(), &home.roots()),
        Binding::Ambiguous {
            candidates: vec![ours, unresolved[0].clone(), unresolved[1].clone()],
            undecided: unresolved,
        },
        "the first 40 MiB attempt leaves too little budget to prove the valid \
         32 MiB sibling lacks the prompt"
    );
}
