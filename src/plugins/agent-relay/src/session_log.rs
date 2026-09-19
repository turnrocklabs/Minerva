// session_log.rs — find the harness session-log file a watched terminal writes.
//
// The binder takes only facts the relay can restate after a restart (profile,
// cwd, the window the terminal was alive, the prompt it submitted last and
// when) and searches the harness's own log tree READ-ONLY. Nothing is
// remembered: the same inputs re-derive the same answer, so a relay restart
// loses no binding.
//
// ONE rule decides a candidate, whatever its size: a file is a candidate iff
// it holds the CURRENT prompt — the most recent one the relay submitted — as a
// user record stamped inside the submit window (SUBMIT_WINDOW_EARLY_MS before
// to SUBMIT_WINDOW_LATE_MS after the submit instant). Older prompts the relay
// still retains are not evidence and are never read: a harness `/clear` opens
// a new file holding none of them, so history would rate a long-lived sibling
// above the terminal's own fresh log. Exactly one candidate binds; several
// refuse (Ambiguous) rather than pick, a wrong transcript being worse than
// none; no candidate is NoLog, which is also what a prompt with no known
// submit instant yields, since no stamp can satisfy an absent window.
//
// Documented limit: two terminals in one project that received the same prompt
// text inside one window are indistinguishable, and are refused together.
//
// Layouts (measured against Claude Code 2.1.277 and codex-cli 0.155.1):
//   claude — <claude config>/projects/<cwd slug>/<session id>.jsonl. Records
//            carry cwd, timestamp and, for user records, the prompt text.
//            Leading records (mode, permission-mode…) carry neither cwd nor
//            timestamp, so the head scan looks past them.
//   codex  — <codex home>/sessions/YYYY/MM/DD/rollout-<local ts>-<thread>.jsonl.
//            The first record is session_meta with cwd, timestamp and
//            originator; prompts are response_item message role=user.
//
// Both formats are documented as unstable: a line that does not parse, or a
// record whose shape is unknown, is skipped and never fatal.
//
// The search runs on the turn path, so every read it makes is bounded, and
// bounded against a length captured once per candidate rather than against the
// growing file: the pruning pass reads at most HEAD_SCAN_BYTES of a file's
// head, the prompt check at most PROMPT_SCAN_BYTES of its tail. The current
// prompt was submitted seconds ago, so a terminal's own log holds it inside
// that tail window. A window whose edge fell inside one record longer than
// TAIL_BOUNDARY_BYTES yields no record at all; that window was not read, so it
// leaves its candidate undecided, and one undecided candidate keeps the whole
// search ambiguous rather than making its neighbour unique.
//
// A file larger than the tail window may hold the prompt ahead of it, so a
// truncated window without the prompt is not proof: the file's modification
// time decides. Last written before the submit (less SLACK_MS), the file took
// no record after it and so cannot hold a prompt written then — Lacks, which
// keeps idle siblings of any size out. Written since, the tail may have pushed
// the prompt out, which leaves the candidate undecided. A window taken from
// offset 0 read every record there is, so lacking the prompt there is Lacks.

use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde_json::Value;

/// Clock-jitter allowance on both ends of the terminal's alive window.
const SLACK_MS: i64 = 2_000;

/// Records read per file in the pruning pass. Enough to reach the first record
/// carrying cwd/timestamp past a harness's preamble records.
const HEAD_RECORDS: usize = 64;

/// Bytes read per file in the pruning pass. A record budget bounds nothing on a
/// file of unparseable lines, which yields no records at all; this bounds that
/// file too. Far above any measured preamble, whose records run to hundreds of
/// bytes each.
pub(crate) const HEAD_SCAN_BYTES: u64 = 256 * 1024;

/// Bytes of a candidate transcript the prompt check may read, taken from the
/// END of the file: the prompt the binder matches on was submitted seconds
/// ago, so the tail is where it is. A larger transcript is judged on its last
/// PROMPT_SCAN_BYTES alone. Bounds one candidate to a read of tens of
/// milliseconds whatever the session's size.
pub(crate) const PROMPT_SCAN_BYTES: u64 = 4 * 1024 * 1024;

/// Bytes at a tail window's opening searched for the newline that ends the
/// record straddling it. The boundary lies one record in, so the search is
/// bounded by a record length; a window whose first TAIL_BOUNDARY_BYTES hold no
/// newline is treated as holding no whole record at all.
pub(crate) const TAIL_BOUNDARY_BYTES: u64 = 256 * 1024;

/// How far before the relay's submit instant the harness may have stamped the
/// record carrying that prompt. A harness stamps it from its own clock, within
/// a second or two of the Enter that submitted it.
pub(crate) const SUBMIT_WINDOW_EARLY_MS: i64 = 2_000;

/// How far after the submit instant that same record may be stamped. Wide
/// enough to absorb a slow disk or a busy box between the Enter and the write,
/// narrow enough that a later send of the same text falls outside it.
pub(crate) const SUBMIT_WINDOW_LATE_MS: i64 = 15_000;

/// Is a record stamped `stamp_ms` the one the relay submitted at
/// `submitted_ms`? Shared by the binder and the answer matcher, which ask the
/// same question of the same instants. A submit time of 0 is an absent
/// measurement, which no stamp satisfies.
pub(crate) fn within_submit_window(submitted_ms: i64, stamp_ms: i64) -> bool {
    submitted_ms != 0
        && stamp_ms >= submitted_ms - SUBMIT_WINDOW_EARLY_MS
        && stamp_ms <= submitted_ms + SUBMIT_WINDOW_LATE_MS
}

/// The interactive originator codex stamps into session_meta. `codex exec`
/// runs write rollouts with the same cwd and the same prompt text (measured),
/// and a watched terminal is always the TUI.
const CODEX_TUI_ORIGINATOR: &str = "codex-tui";

// ---------------------------------------------------------------------------
// Inputs and outcome
// ---------------------------------------------------------------------------

/// Everything the binder is allowed to know about a watched terminal. Each
/// field must be re-derivable after a relay restart.
#[derive(Debug, Clone)]
pub struct TerminalFacts {
    /// Watch profile id: "claude" or "codex" have known log layouts.
    pub profile_id: String,
    /// Absolute working directory the harness was launched in, when known.
    pub cwd: Option<PathBuf>,
    /// Epoch-ms lower bound of the terminal's life.
    pub window_start_ms: i64,
    /// Epoch-ms upper bound; None means "still running".
    pub window_end_ms: Option<i64>,
    /// Exact body of the prompt the relay submitted last, None when it has
    /// submitted none. Earlier prompts are not evidence and are not carried.
    pub current_prompt: Option<String>,
    /// Epoch ms at which `current_prompt` was submitted, 0 when unknown.
    pub current_submitted_ms: i64,
}

/// Where each harness keeps its logs.
#[derive(Debug, Clone)]
pub struct LogRoots {
    pub claude_projects: PathBuf,
    pub codex_sessions: PathBuf,
}

impl LogRoots {
    /// The default roots under a home directory. Takes no environment, so a
    /// caller pointing at a constructed tree gets exactly that tree.
    pub fn for_home(home: &Path) -> Self {
        LogRoots {
            claude_projects: home.join(".claude/projects"),
            codex_sessions: home.join(".codex/sessions"),
        }
    }

    /// Roots for the running user, with each harness's own home override
    /// applied. None when no home directory is known.
    pub fn from_env() -> Option<Self> {
        let home = std::env::var_os("HOME")
            .or_else(|| std::env::var_os("USERPROFILE"))
            .map(PathBuf::from)?;
        let mut roots = LogRoots::for_home(&home);
        if let Some(dir) = std::env::var_os("CLAUDE_CONFIG_DIR") {
            roots.claude_projects = PathBuf::from(dir).join("projects");
        }
        if let Some(dir) = std::env::var_os("CODEX_HOME") {
            roots.codex_sessions = PathBuf::from(dir).join("sessions");
        }
        Some(roots)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Binding {
    /// Exactly one file matches every filter.
    Bound(PathBuf),
    /// The harness wrote no log for this terminal (or none that still matches).
    NoLog,
    /// Several files survive; the caller must not treat any of them as the log.
    /// `undecided` names those whose prompt window could not be read at all, so
    /// nothing about them was established either way.
    Ambiguous {
        candidates: Vec<PathBuf>,
        undecided: Vec<PathBuf>,
    },
    /// Profile has no known log layout.
    Unsupported(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Harness {
    Claude,
    Codex,
}

impl Harness {
    fn from_profile_id(profile_id: &str) -> Option<Harness> {
        match profile_id {
            "claude" => Some(Harness::Claude),
            "codex" => Some(Harness::Codex),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// Binder
// ---------------------------------------------------------------------------

/// Locate the session log belonging to one watched terminal.
///
/// Filters, in order: layout (project slug / date directories) → recorded cwd
/// → alive-window overlap → codex originator → the current prompt recorded
/// inside its submit window. Survivors are compared by path, so the outcome
/// does not depend on directory iteration order. A candidate the prompt filter
/// could not read keeps every survivor ambiguous: a file ruled out only by the
/// edge of a bounded read would otherwise manufacture a unique match for its
/// neighbour.
pub fn bind(facts: &TerminalFacts, roots: &LogRoots) -> Binding {
    let Some(harness) = Harness::from_profile_id(&facts.profile_id) else {
        return Binding::Unsupported(facts.profile_id.clone());
    };

    // The current prompt is the only evidence that ties a file to this
    // terminal; cwd and time alone never bind, so no prompt means no log. A
    // prompt with no submit instant has no window for its record to fall in,
    // which no evidence can make up for, so it is settled here, before a
    // directory is listed or a byte of any candidate is read.
    if facts.current_prompt.is_none() || facts.current_submitted_ms == 0 {
        return Binding::NoLog;
    }

    let mut candidates: Vec<PathBuf> = match harness {
        Harness::Claude => claude_candidates(&roots.claude_projects, facts.cwd.as_deref()),
        Harness::Codex => codex_candidates(&roots.codex_sessions, facts),
    };
    candidates.sort();

    let surviving: Vec<PathBuf> = candidates
        .into_iter()
        .filter(|path| head_matches(path, harness, facts))
        .collect();
    if surviving.is_empty() {
        return Binding::NoLog;
    }

    let mut matched: Vec<PathBuf> = Vec::new();
    let mut undecided: Vec<PathBuf> = Vec::new();
    for path in surviving {
        let len = file_len(&path);
        match prompt_evidence(&path, harness, facts, len) {
            PromptEvidence::Holds => matched.push(path),
            PromptEvidence::Undecided => undecided.push(path),
            PromptEvidence::Lacks => {}
        }
    }
    if undecided.is_empty() {
        return resolve(matched);
    }
    let mut candidates = matched;
    candidates.extend(undecided.iter().cloned());
    candidates.sort();
    Binding::Ambiguous {
        candidates,
        undecided,
    }
}

fn resolve(mut survivors: Vec<PathBuf>) -> Binding {
    match survivors.len() {
        0 => Binding::NoLog,
        1 => Binding::Bound(survivors.remove(0)),
        _ => Binding::Ambiguous {
            candidates: survivors,
            undecided: Vec::new(),
        },
    }
}

// ---------------------------------------------------------------------------
// Candidate enumeration
// ---------------------------------------------------------------------------

/// Claude Code's project directory name: every non-alphanumeric byte of the
/// absolute cwd becomes '-', with no collapsing of runs.
pub fn claude_project_slug(cwd: &Path) -> String {
    cwd.to_string_lossy()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

fn claude_candidates(root: &Path, cwd: Option<&Path>) -> Vec<PathBuf> {
    let dirs: Vec<PathBuf> = match cwd {
        // The slug is lossy — distinct cwds can share one directory — so the
        // recorded cwd is still checked per file.
        Some(cwd) => vec![root.join(claude_project_slug(cwd))],
        None => read_dir_sorted(root)
            .into_iter()
            .filter(|p| p.is_dir())
            .collect(),
    };
    dirs.iter()
        .flat_map(|dir| read_dir_sorted(dir))
        .filter(|p| p.is_file() && has_extension(p, "jsonl"))
        .collect()
}

fn codex_candidates(root: &Path, facts: &TerminalFacts) -> Vec<PathBuf> {
    // Only days after the terminal died are impossible: a rollout is named for
    // the day the session STARTED, which may be long before the window on a
    // terminal that has been running for days. The bound is widened by a day
    // because directory dates are local while record timestamps are UTC.
    let last_day = facts
        .window_end_ms
        .map(|ms| epoch_day(ms) + 1)
        .unwrap_or(i64::MAX);

    let mut out = Vec::new();
    for year_dir in read_dir_sorted(root) {
        let Some(year) = dir_number(&year_dir) else {
            continue;
        };
        for month_dir in read_dir_sorted(&year_dir) {
            let Some(month) = dir_number(&month_dir) else {
                continue;
            };
            for day_dir in read_dir_sorted(&month_dir) {
                let Some(day) = dir_number(&day_dir) else {
                    continue;
                };
                if days_from_civil(year, month, day) > last_day {
                    continue;
                }
                out.extend(read_dir_sorted(&day_dir).into_iter().filter(|p| {
                    p.is_file()
                        && has_extension(p, "jsonl")
                        && p.file_name()
                            .and_then(|n| n.to_str())
                            .is_some_and(|n| n.starts_with("rollout-"))
                }));
            }
        }
    }
    out
}

fn read_dir_sorted(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut paths: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
    paths.sort();
    paths
}

fn has_extension(path: &Path, ext: &str) -> bool {
    path.extension().and_then(|e| e.to_str()) == Some(ext)
}

fn dir_number(path: &Path) -> Option<i64> {
    path.file_name()?.to_str()?.parse().ok()
}

// ---------------------------------------------------------------------------
// Cheap pruning pass
// ---------------------------------------------------------------------------

#[derive(Debug, Default)]
struct Head {
    cwd: Option<String>,
    first_ts_ms: Option<i64>,
    originator: Option<String>,
}

/// Does this file's opening records place it in the terminal's directory and
/// life window? A file with no readable timestamp is evidence of nothing and
/// is dropped.
fn head_matches(path: &Path, harness: Harness, facts: &TerminalFacts) -> bool {
    let head = scan_head(path, harness);
    let Some(first_ms) = head.first_ts_ms else {
        return false;
    };

    if let (Some(recorded), Some(wanted)) = (head.cwd.as_deref(), facts.cwd.as_deref()) {
        if !same_dir(Path::new(recorded), wanted) {
            return false;
        }
    }
    if harness == Harness::Codex {
        if let Some(originator) = head.originator.as_deref() {
            if originator != CODEX_TUI_ORIGINATOR {
                return false;
            }
        }
    }

    // Last activity comes from the file's mtime: the logs are append-only, and
    // reading every transcript to the end just to learn when it stopped would
    // cost more than the whole binding.
    let last_ms = file_mtime_ms(path).unwrap_or(first_ms).max(first_ms);
    let start = facts.window_start_ms.saturating_sub(SLACK_MS);
    let end = facts
        .window_end_ms
        .unwrap_or(i64::MAX)
        .saturating_add(SLACK_MS);
    last_ms >= start && first_ms <= end
}

fn scan_head(path: &Path, harness: Harness) -> Head {
    let mut head = Head::default();
    for record in read_records_from(path, 0, HEAD_SCAN_BYTES).take(HEAD_RECORDS) {
        match harness {
            Harness::Claude => {
                if head.cwd.is_none() {
                    head.cwd = record
                        .get("cwd")
                        .and_then(|v| v.as_str())
                        .map(str::to_string);
                }
                if head.first_ts_ms.is_none() {
                    head.first_ts_ms = record
                        .get("timestamp")
                        .and_then(|v| v.as_str())
                        .and_then(parse_iso_ms);
                }
            }
            Harness::Codex => {
                if record.get("type").and_then(|v| v.as_str()) == Some("session_meta") {
                    if let Some(payload) = record.get("payload") {
                        head.cwd = payload
                            .get("cwd")
                            .and_then(|v| v.as_str())
                            .map(str::to_string);
                        head.originator = payload
                            .get("originator")
                            .and_then(|v| v.as_str())
                            .map(str::to_string);
                    }
                }
                if head.first_ts_ms.is_none() {
                    head.first_ts_ms = record
                        .get("timestamp")
                        .and_then(|v| v.as_str())
                        .and_then(parse_iso_ms);
                }
            }
        }
        if head.first_ts_ms.is_some() && head.cwd.is_some() {
            break;
        }
    }
    head
}

/// Symlinked temp roots (/tmp vs /private/tmp on macOS) make raw string
/// comparison too strict; a recorded directory that no longer exists keeps the
/// raw comparison as its only answer.
fn same_dir(a: &Path, b: &Path) -> bool {
    let trim = |p: &Path| p.to_string_lossy().trim_end_matches('/').to_string();
    if trim(a) == trim(b) {
        return true;
    }
    match (fs::canonicalize(a), fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

/// Length of a file the binder is about to read, 0 when it cannot be measured.
/// Captured once per candidate: every bound the prompt check applies is
/// measured against this number, so a harness appending under the call cannot
/// stretch a window past what was measured.
fn file_len(path: &Path) -> u64 {
    fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

fn file_mtime_ms(path: &Path) -> Option<i64> {
    let modified = fs::metadata(path).and_then(|m| m.modified()).ok()?;
    match modified.duration_since(UNIX_EPOCH) {
        Ok(d) => Some(d.as_millis() as i64),
        Err(e) => Some(-(e.duration().as_millis() as i64)),
    }
}

// ---------------------------------------------------------------------------
// Prompt evidence
// ---------------------------------------------------------------------------

/// What one candidate's prompt window says about it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PromptEvidence {
    /// A candidate: the window holds the current prompt as a user record
    /// stamped inside the submit window.
    Holds,
    /// Not this terminal's log, for this search: a window taken from offset 0
    /// held every record there is and not the prompt, or a truncated window
    /// lacked it on a file last written before the submit, which therefore took
    /// no record carrying it.
    Lacks,
    /// Nothing is established either way. Either the window could not be read —
    /// its edge fell inside a record longer than TAIL_BOUNDARY_BYTES, so it
    /// yielded no record at all — or it was read without the prompt on a file
    /// written since the submit, where the tail may have pushed that prompt out
    /// of the window.
    Undecided,
}

/// Judge one candidate against a length its caller captured.
pub(crate) fn prompt_evidence(
    path: &Path,
    harness: Harness,
    facts: &TerminalFacts,
    len: u64,
) -> PromptEvidence {
    let Some(current) = facts.current_prompt.as_deref() else {
        return PromptEvidence::Lacks;
    };
    // No submit instant is no window, and no window admits a record.
    if facts.current_submitted_ms == 0 {
        return PromptEvidence::Lacks;
    }
    // A non-zero offset is the whole of "this file is larger than the window".
    let from = tail_offset_within(path, PROMPT_SCAN_BYTES, len);
    let budget = len.saturating_sub(from).min(PROMPT_SCAN_BYTES);
    let scan = scan_prompt_window(
        path,
        harness,
        current,
        facts.current_submitted_ms,
        from,
        budget,
    );
    if scan.in_window {
        return PromptEvidence::Holds;
    }
    if from == 0 {
        return PromptEvidence::Lacks;
    }
    if scan.records == 0 {
        return PromptEvidence::Undecided;
    }
    // Truncated and lacking: only a write at or after the submit could have
    // carried the prompt and then pushed it out of the window.
    match file_mtime_ms(path) {
        Some(mtime) if mtime < facts.current_submitted_ms - SLACK_MS => PromptEvidence::Lacks,
        _ => PromptEvidence::Undecided,
    }
}

/// What one pass over a candidate's tail window found.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct WindowScan {
    /// A user record in the window carries the current prompt and is stamped
    /// inside its submit window.
    in_window: bool,
    /// Records the window yielded; zero means the window was never read.
    records: usize,
}

/// Read a candidate's tail window for the one question the evidence rests on.
/// Only `budget` bytes from `from` are read — the window the caller's captured
/// length names, never what the file grew to since — and the scan stops the
/// moment a record settles the question.
fn scan_prompt_window(
    path: &Path,
    harness: Harness,
    current: &str,
    submitted_ms: i64,
    from: u64,
    budget: u64,
) -> WindowScan {
    let mut texts: Vec<String> = Vec::new();
    let mut scan = WindowScan::default();
    for record in read_records_from(path, from, budget) {
        scan.records += 1;
        texts.clear();
        collect_user_texts(harness, &record, &mut texts);
        if !texts.iter().any(|text| prompt_matches(current, text)) {
            continue;
        }
        let stamped = record
            .get("timestamp")
            .and_then(|v| v.as_str())
            .and_then(parse_iso_ms);
        // A record with no readable stamp is no temporal evidence, and a repeat
        // of the prompt outside the window belongs to another turn; either way
        // the scan reads on, because a later record may still be the one.
        if stamped.is_some_and(|ms| within_submit_window(submitted_ms, ms)) {
            scan.in_window = true;
            break;
        }
    }
    scan
}

fn collect_user_texts(harness: Harness, record: &Value, out: &mut Vec<String>) {
    match harness {
        Harness::Claude => {
            if record.get("type").and_then(|v| v.as_str()) != Some("user") {
                return;
            }
            // Sidechain records belong to sub-agents, not to this terminal.
            if record.get("isSidechain").and_then(|v| v.as_bool()) == Some(true) {
                return;
            }
            match record.pointer("/message/content") {
                Some(Value::String(text)) => out.push(text.clone()),
                Some(Value::Array(blocks)) => push_text_blocks(blocks, out, &["text"]),
                _ => {}
            }
        }
        Harness::Codex => {
            if record.get("type").and_then(|v| v.as_str()) != Some("response_item") {
                return;
            }
            let Some(payload) = record.get("payload") else {
                return;
            };
            if payload.get("type").and_then(|v| v.as_str()) != Some("message")
                || payload.get("role").and_then(|v| v.as_str()) != Some("user")
            {
                return;
            }
            if let Some(Value::Array(blocks)) = payload.get("content") {
                push_text_blocks(blocks, out, &["input_text", "text"]);
            }
        }
    }
}

fn push_text_blocks(blocks: &[Value], out: &mut Vec<String>, kinds: &[&str]) {
    for block in blocks {
        let kind = block.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if !kinds.contains(&kind) {
            continue;
        }
        if let Some(text) = block.get("text").and_then(|v| v.as_str()) {
            out.push(text.to_string());
        }
    }
}

/// A prompt matches a recorded user text when it IS that text, or is one whole
/// line of it (harnesses prepend context blocks to the same message). Looser
/// containment would let a two-character prompt match any transcript.
pub fn prompt_matches(prompt: &str, text: &str) -> bool {
    let wanted = squeeze_whitespace(prompt);
    if wanted.is_empty() {
        return false;
    }
    squeeze_whitespace(text) == wanted
        || text.lines().any(|line| squeeze_whitespace(line) == wanted)
}

fn squeeze_whitespace(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

// ---------------------------------------------------------------------------
// JSONL reading
// ---------------------------------------------------------------------------

/// Offset of the first whole record inside the last `budget` bytes of a file,
/// measured against the file's length now. Shared with the extractor, which
/// opens a fresh bind on a tail window for the same reason.
pub(crate) fn tail_offset(path: &Path, budget: u64) -> u64 {
    tail_offset_within(path, budget, file_len(path))
}

/// `tail_offset` against a length its caller captured: 0 while that length is
/// inside `budget`, otherwise just past the newline that ends the partial
/// record straddling the window's edge. The search for that newline is bounded
/// by TAIL_BOUNDARY_BYTES and by the window itself, so it never reads bytes
/// appended since `len` was taken, and the offset it returns is never past
/// `len`. Every answer but a found boundary is `len` itself, a window that
/// yields no records at all: no newline inside the bound is no boundary, and a
/// file that cannot be opened or sought has no boundary either — returning 0
/// there would hand the caller the whole file as its window.
pub(crate) fn tail_offset_within(path: &Path, budget: u64, len: u64) -> u64 {
    if len <= budget {
        return 0;
    }
    let window = len - budget;
    let Ok(mut file) = fs::File::open(path) else {
        return len;
    };
    if file.seek(SeekFrom::Start(window)).is_err() {
        return len;
    }
    let mut reader = BufReader::new(file.take(TAIL_BOUNDARY_BYTES.min(budget)));
    let mut partial = Vec::new();
    match reader.read_until(b'\n', &mut partial) {
        Ok(read) if partial.last() == Some(&b'\n') => window + read as u64,
        _ => len,
    }
}

/// Stream a .jsonl file as records from a byte offset that must name a record
/// boundary, skipping lines that do not parse. The budget bounds the READER,
/// not a count kept beside it, so one enormous line cannot be read or allocated
/// past it; the record the limit cuts in half is dropped rather than parsed.
/// Bytes are decoded lossily so a corrupt line cannot hide the records around
/// it, and the budget counts those unparsed bytes too — it is what bounds a
/// file that yields no records at all.
fn read_records_from(path: &Path, start: u64, budget: u64) -> impl Iterator<Item = Value> {
    let mut reader = fs::File::open(path).ok().and_then(|mut file| {
        file.seek(SeekFrom::Start(start)).ok()?;
        Some(BufReader::new(file.take(budget)))
    });
    let mut buf: Vec<u8> = Vec::new();
    std::iter::from_fn(move || {
        let reader = reader.as_mut()?;
        loop {
            buf.clear();
            match reader.read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => return None,
                Ok(_) => {
                    // No newline with the budget spent is the limit cutting a
                    // record: those bytes are half a record, never a record.
                    if buf.last() != Some(&b'\n') && reader.get_ref().limit() == 0 {
                        return None;
                    }
                    let parsed = {
                        let line = String::from_utf8_lossy(&buf);
                        serde_json::from_str::<Value>(line.trim()).ok()
                    };
                    if let Some(record) = parsed {
                        return Some(record);
                    }
                }
            }
        }
    })
}

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

/// Parse an ISO-8601 instant ("2026-09-19T01:17:26.987Z", or with a ±HH:MM
/// offset) to epoch milliseconds. Anything else yields None.
pub(crate) fn parse_iso_ms(s: &str) -> Option<i64> {
    let bytes = s.as_bytes();
    if bytes.len() < 19 || bytes[10] != b'T' {
        return None;
    }
    let num = |range: std::ops::Range<usize>| s.get(range)?.parse::<i64>().ok();
    let year = num(0..4)?;
    let month = num(5..7)?;
    let day = num(8..10)?;
    let hour = num(11..13)?;
    let minute = num(14..16)?;
    let second = num(17..19)?;

    let rest = &s[19..];
    let (frac, zone) = match rest.strip_prefix('.') {
        Some(after_dot) => {
            let digits: String = after_dot
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .collect();
            let millis = format!("{digits:0<3}")[..3].parse::<i64>().ok()?;
            (millis, &after_dot[digits.len()..])
        }
        None => (0, rest),
    };

    let offset_ms = match zone.as_bytes().first() {
        None | Some(b'Z') | Some(b'z') => 0,
        Some(sign @ (b'+' | b'-')) => {
            let hours = zone.get(1..3)?.parse::<i64>().ok()?;
            let minutes = zone
                .get(4..6)
                .or_else(|| zone.get(3..5))
                .and_then(|m| m.parse::<i64>().ok())
                .unwrap_or(0);
            let magnitude = (hours * 60 + minutes) * 60_000;
            if *sign == b'+' {
                -magnitude
            } else {
                magnitude
            }
        }
        _ => return None,
    };

    let days = days_from_civil(year, month, day);
    Some(days * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1_000 + frac + offset_ms)
}

/// Days since 1970-01-01 for a proleptic-Gregorian date (Hinnant's algorithm).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn epoch_day(ms: i64) -> i64 {
    ms.div_euclid(86_400_000)
}
