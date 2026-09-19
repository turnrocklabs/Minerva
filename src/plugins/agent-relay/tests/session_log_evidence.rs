// session_log_evidence.rs — what a transcript larger than the prompt window
// proves when that window does not hold the current prompt.
//
// The window is the last PROMPT_SCAN_BYTES of a file, so a prompt the harness
// recorded can sit ahead of it. The file's last write is what separates the two
// cases: a file written since the submit may have pushed the prompt out of the
// window and is undecided, while one last written before the submit took no
// record carrying that prompt at all and is ruled out whatever its size.
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
    let bytes = session_log::PROMPT_SCAN_BYTES as usize + 64 * 1024;
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
/// more than the window holds, which pushed that record out of it. Our log was
/// written after the submit, so its window is no evidence against it: the
/// search is refused with ours undecided, and the sibling — the one file whose
/// window does hold the prompt — is never bound on its own.
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
            undecided: vec![ours],
        },
        "a window our own log outgrew since the submit decides nothing, and \
         cannot make the sibling unique"
    );
}

/// The idle neighbouring tab: a transcript larger than the prompt window that
/// never received the current prompt. Its last write precedes the submit, so no
/// record carrying that prompt can be in it at all and it is ruled out on size
/// alone being irrelevant. The same file written since the submit proves
/// nothing, and the search is refused instead.
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
        Binding::Ambiguous {
            candidates: vec![ours, sibling.clone()],
            undecided: vec![sibling],
        },
        "written since the submit, the same file's window proves nothing"
    );
}
