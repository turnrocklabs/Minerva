// turn_extract.rs — turns out of a harness session log, incrementally.
//
// A pure read over (path, cursor) -> (turns, cursor). Nothing is remembered
// between calls: the cursor is a byte offset, so the same file and the same
// offset always yield the same turns, and a relay restart loses nothing.
//
// The cursor only ever advances past a line that left the extractor holding no
// partial turn. An unfinished turn's lines are therefore re-read on the next
// call, which bounds re-reading to one turn rather than to the whole file and
// keeps a turn from being emitted twice.
//
// Reading is bounded at both ends: a caller with no cursor yet starts at
// `tail_cursor`, the last FRESH_BIND_TAIL_BYTES of the file, and one call holds
// at most MAX_RETAINED_TURNS completed turns. A turn that closed before the
// tail window is never offered.
//
// A cursor bounds nothing by itself — a log can grow by any amount between two
// reads — so the same tail rule takes over for a span longer than
// MAX_SPAN_BYTES, and `Extraction::skipped` tells the caller that the turns
// between the cursor and that window are gone. The file's length is captured
// once per call, and both the read and that tail window are measured against
// it, so a harness still appending can neither grow the span the budget was
// measured against nor move the window off a record boundary. One turn is bounded by
// MAX_TURN_BYTES: a turn that outgrows it is dropped whole, never truncated
// into text that reads like a complete answer.
//
// A turn only ever ends at its own end marker or at the record that opens the
// next turn: a prompt (claude) or task_started (codex) closes whatever is still
// open as unusable and drops it, because a turn the harness never closed has no
// answer worth delivering and holding it would swallow the turn behind it.
//
// Turn boundaries (measured against Claude Code 2.1.277 and codex-cli 0.155.1):
//   claude — a turn opens at a user record carrying typed text and closes at
//            the first system/turn_duration record (normal) or at a user
//            record whose text opens "[Request interrupted by user"
//            (interrupted) — the bare form for a stopped response, a
//            "for tool use" variant for a denied permission. No
//            turn_duration follows an interrupt. The harness can write several
//            turn_duration records between two prompts, one per non-user
//            trigger (task notifications, queued messages); cutting at the
//            first keeps a turn to the work its own prompt started.
//   codex  — a turn opens at event_msg task_started and closes at task_complete
//            (normal) or turn_aborted (interrupted).
//
// Not every claude user record is typed text: isMeta rows, tag-wrapped
// scaffolding, tool_result carriers and the summary an automatic compaction
// writes are the harness talking to itself, and none of them opens or closes a
// turn — the turn running when one lands keeps running.
//
// Answer text is the source form the harness recorded. Claude states it as the
// text blocks of the turn's assistant records, joined by a blank line; codex
// states its own in task_complete.last_agent_message and that wins over the
// streamed assistant messages. Codex records no partial answer for a turn it
// aborted, so an interrupted codex turn has an empty answer by construction
// while an interrupted claude turn carries the partial text.
//
// Codex writes no rollout record for a local slash command, and no rollout file
// at all for a session whose only activity is one, so slash commands are a
// claude-only shape here.
//
// Both formats are documented as unstable: an unparseable line and a record of
// an unknown shape are skipped, never fatal.

use std::fs::File;
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

use serde_json::Value;

use crate::session_log;

/// Opening of the claude records that mark an aborted response. The harness
/// writes a bare "[Request interrupted by user]" and a
/// "[Request interrupted by user for tool use]" variant for a denied
/// permission, so the marker is matched by prefix rather than whole text.
const CLAUDE_INTERRUPT_PREFIX: &str = "[Request interrupted by user";

/// Separator between the text pieces of one answer or one prompt.
const PIECE_JOIN: &str = "\n\n";

/// Bytes read back from the end of a transcript a caller has no cursor into.
/// Every turn before that window was answered on the screen long ago, so only
/// the recent records can name the turn being delivered; reading from offset 0
/// would walk a whole session's history for one answer.
pub const FRESH_BIND_TAIL_BYTES: u64 = 1024 * 1024;

/// Bytes of unread log one extraction may parse. A turn appends kilobytes to a
/// few megabytes, so a span past this is a log that grew while nothing read it,
/// and parsing it whole would run on the turn path. Such a span is skipped to
/// the tail window instead.
pub const MAX_SPAN_BYTES: u64 = 8 * 1024 * 1024;

/// Text one turn may accumulate. A delivered answer is truncated to tens of
/// thousands of characters, so nothing under this cap is ever lost by it, and
/// a turn that passes it cannot grow with the file.
pub(crate) const MAX_TURN_BYTES: usize = 1024 * 1024;

/// Completed turns one extraction may hold, oldest dropped first. The matcher
/// wants the turn the relay just drove, so only the last few can ever win, and
/// the cap keeps a long read from holding every answer in the file at once.
const MAX_RETAINED_TURNS: usize = 8;

// ---------------------------------------------------------------------------
// Result shapes
// ---------------------------------------------------------------------------

/// Which harness wrote the log. The binder's profile id selects it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Harness {
    Claude,
    Codex,
}

impl Harness {
    pub fn from_profile_id(profile_id: &str) -> Option<Harness> {
        match profile_id {
            "claude" => Some(Harness::Claude),
            "codex" => Some(Harness::Codex),
            _ => None,
        }
    }
}

/// How the harness ended the turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnEnd {
    Normal,
    Interrupted,
}

/// A local slash command the harness handled itself, with whatever it printed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SlashCommand {
    /// Command as typed, leading slash included.
    pub name: String,
    pub args: String,
    pub stdout: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Turn {
    pub prompt: String,
    /// Markdown, in the source form the harness recorded.
    pub answer: String,
    /// Epoch milliseconds stamped on the record that opened the turn, 0 when
    /// that record carried no readable timestamp.
    pub start_ms: i64,
    pub end: TurnEnd,
    pub slash_commands: Vec<SlashCommand>,
}

/// Position in the log that the next extraction resumes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Cursor {
    pub offset: u64,
}

impl Cursor {
    /// Read the file from its first byte. A rotated file resumes here, and so
    /// does a caller that means to read a whole transcript.
    pub fn start() -> Cursor {
        Cursor { offset: 0 }
    }
}

/// Where to begin reading a log nothing has read before: the first whole record
/// within the last FRESH_BIND_TAIL_BYTES. An unreadable file yields the start
/// of the file, which the extraction itself then fails on.
pub fn tail_cursor(path: &Path) -> Cursor {
    Cursor {
        offset: session_log::tail_offset(path, FRESH_BIND_TAIL_BYTES),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Extraction {
    pub turns: Vec<Turn>,
    pub cursor: Cursor,
    /// True when the read began past the cursor because the span between them
    /// was over budget. The turns of that span were never parsed, so the
    /// cursor vouches for no turn and the caller must treat a turn it cannot
    /// find here as unavailable rather than as absent.
    pub skipped: bool,
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/// Read the turns that completed after `cursor`, and where to resume. At most
/// MAX_RETAINED_TURNS are returned, the most recent ones.
pub fn extract(path: &Path, harness: Harness, cursor: Cursor) -> io::Result<Extraction> {
    let len = File::open(path)?.metadata()?.len();
    extract_within(path, harness, cursor, len)
}

/// `extract` against a file length captured once by its caller. Every bound the
/// call makes is measured against that one length and the read is limited to
/// it, so a harness appending while the read runs cannot stretch the span past
/// MAX_SPAN_BYTES; a record the length cuts in half is left for the next call.
pub(crate) fn extract_within(
    path: &Path,
    harness: Harness,
    cursor: Cursor,
    len: u64,
) -> io::Result<Extraction> {
    let mut file = File::open(path)?;
    // A file shorter than the cursor was rotated or rewritten, so the old
    // offset names nothing in the bytes that are there now.
    let resume = if cursor.offset > len {
        Cursor::start()
    } else {
        cursor
    };
    // Over-budget span: fall back to the tail window a fresh bind reads, which
    // costs one bounded read whatever the file did since the last call.
    let skipped = len.saturating_sub(resume.offset) > MAX_SPAN_BYTES;
    // Aligned against the captured length, never against the live file: an
    // append since `len` would otherwise move the window past it and open the
    // read inside a record whose opening bytes are then lost.
    let start = if skipped {
        session_log::tail_offset_within(path, FRESH_BIND_TAIL_BYTES, len)
    } else {
        resume.offset
    };
    file.seek(SeekFrom::Start(start))?;
    let mut reader = BufReader::new(file.take(len - start));

    let mut extractor = Extractor::new(harness);
    let mut turns = Vec::new();
    let mut position = start;
    let mut committed = start;
    let mut buf: Vec<u8> = Vec::new();
    loop {
        buf.clear();
        let read = reader.read_until(b'\n', &mut buf)?;
        // A tail with no newline is a record still being written. Leaving
        // `position` short of it is what lets the next call re-read it whole.
        if read == 0 || buf.last() != Some(&b'\n') {
            break;
        }
        position += read as u64;
        let parsed = {
            // Lossy decoding so that one mangled line cannot hide its
            // neighbours behind an encoding error.
            let line = String::from_utf8_lossy(&buf);
            serde_json::from_str::<Value>(line.trim()).ok()
        };
        if let Some(record) = parsed {
            extractor.feed(&record, &mut turns);
            if turns.len() > MAX_RETAINED_TURNS {
                turns.drain(..turns.len() - MAX_RETAINED_TURNS);
            }
        }
        if extractor.is_idle() {
            committed = position;
        }
    }

    Ok(Extraction {
        turns,
        cursor: Cursor { offset: committed },
        skipped,
    })
}

/// A turn being built up, before its end marker is known.
#[derive(Default)]
struct OpenTurn {
    prompt: String,
    start_ms: i64,
    answer_parts: Vec<String>,
    /// The answer the harness states for itself, which wins over the parts.
    stated_answer: Option<String>,
    slash_commands: Vec<SlashCommand>,
    /// True while the turn exists only to carry a slash command, which no
    /// end marker of its own ever closes.
    command_only: bool,
    /// Text charged against MAX_TURN_BYTES so far.
    bytes: usize,
    /// Set once that cap was passed. The turn is then dropped whole: half a
    /// runaway turn would still read as a complete answer.
    oversize: bool,
}

impl OpenTurn {
    /// Open a turn on the prompt that started it.
    fn opened(prompt: String, start_ms: i64) -> OpenTurn {
        let mut open = OpenTurn {
            start_ms,
            ..Default::default()
        };
        open.take_prompt(prompt);
        open
    }

    /// Charge `len` bytes of text against the cap, and say whether the turn may
    /// still hold text. Everything held is released at the crossing, so an open
    /// turn never grows past the cap.
    fn charge(&mut self, len: usize) -> bool {
        self.bytes = self.bytes.saturating_add(len);
        if self.bytes > MAX_TURN_BYTES && !self.oversize {
            self.oversize = true;
            self.prompt = String::new();
            self.answer_parts = Vec::new();
            self.stated_answer = None;
            self.slash_commands = Vec::new();
        }
        !self.oversize
    }

    fn take_prompt(&mut self, text: String) {
        if self.charge(text.len()) {
            self.prompt = text;
        }
    }

    fn push_answer(&mut self, text: String) {
        if self.charge(text.len()) {
            self.answer_parts.push(text);
        }
    }

    fn state_answer(&mut self, text: String) {
        if self.charge(text.len()) {
            self.stated_answer = Some(text);
        }
    }

    fn push_command(&mut self, command: SlashCommand) {
        if self.charge(command.name.len() + command.args.len() + command.stdout.len()) {
            self.slash_commands.push(command);
        }
    }

    /// The finished turn, or None when it outgrew the cap and is unusable.
    fn finish(self, end: TurnEnd) -> Option<Turn> {
        if self.oversize {
            return None;
        }
        let answer = self
            .stated_answer
            .unwrap_or_else(|| self.answer_parts.join(PIECE_JOIN));
        Some(Turn {
            prompt: self.prompt,
            answer,
            start_ms: self.start_ms,
            end,
            slash_commands: self.slash_commands,
        })
    }
}

struct Extractor {
    harness: Harness,
    open: Option<OpenTurn>,
}

impl Extractor {
    fn new(harness: Harness) -> Extractor {
        Extractor {
            harness,
            open: None,
        }
    }

    /// Is every record so far accounted for by an emitted turn? Only then may
    /// the cursor move past the line just read.
    fn is_idle(&self) -> bool {
        self.open.is_none()
    }

    fn feed(&mut self, record: &Value, out: &mut Vec<Turn>) {
        match self.harness {
            Harness::Claude => self.feed_claude(record, out),
            Harness::Codex => self.feed_codex(record, out),
        }
    }

    fn close(&mut self, end: TurnEnd, out: &mut Vec<Turn>) {
        if let Some(turn) = self.open.take().and_then(|open| open.finish(end)) {
            out.push(turn);
        }
    }

    /// Emit a slash-command turn that conversation content has now overtaken.
    fn flush_command_turn(&mut self, out: &mut Vec<Turn>) {
        if matches!(self.open.as_ref(), Some(open) if open.command_only) {
            self.close(TurnEnd::Normal, out);
        }
    }

    /// A command typed between turns becomes a turn of its own; one typed while
    /// a turn is open rides along on that turn.
    fn attach_command(&mut self, command: SlashCommand, start_ms: i64, out: &mut Vec<Turn>) {
        self.flush_command_turn(out);
        match self.open.as_mut() {
            Some(open) => open.push_command(command),
            None => {
                let mut prompt = command.name.clone();
                if !command.args.is_empty() {
                    prompt.push(' ');
                    prompt.push_str(&command.args);
                }
                let mut open = OpenTurn::opened(prompt, start_ms);
                open.command_only = true;
                open.push_command(command);
                self.open = Some(open);
            }
        }
    }

    fn feed_claude(&mut self, record: &Value, out: &mut Vec<Turn>) {
        let kind = record["type"].as_str().unwrap_or_default();
        let stamped_ms = record_ms(record);
        // The slash-command tags read the same whether the harness files them
        // as a user record or as a system/local_command record. Answer text is
        // never scanned for them, so an answer quoting a tag cannot pose as one.
        let tagged = if kind == "user" || kind == "system" {
            claude_tagged_body(record)
        } else {
            String::new()
        };
        if let Some(name) = tag_body(&tagged, "command-name") {
            self.attach_command(
                SlashCommand {
                    name,
                    args: tag_body(&tagged, "command-args").unwrap_or_default(),
                    stdout: String::new(),
                },
                stamped_ms,
                out,
            );
            return;
        }
        if let Some(stdout) = tag_body(&tagged, "local-command-stdout") {
            let mut command_turn_done = false;
            if let Some(open) = self.open.as_mut() {
                if open.charge(stdout.len()) {
                    if let Some(command) = open.slash_commands.last_mut() {
                        command.stdout = stdout;
                    }
                }
                command_turn_done = open.command_only;
            }
            if command_turn_done {
                self.close(TurnEnd::Normal, out);
            }
            return;
        }

        match kind {
            "user" => {
                let message = &record["message"];
                if has_tool_result(message) {
                    return;
                }
                let text = message_text(message);
                let trimmed = text.trim();
                if trimmed.starts_with(CLAUDE_INTERRUPT_PREFIX) {
                    self.close(TurnEnd::Interrupted, out);
                    return;
                }
                // isMeta rows, tag-wrapped scaffolding and the summary an
                // automatic compaction writes are the harness talking to
                // itself, not anything the user typed. The compaction summary
                // is plain prose and carries neither mark, so it is recognised
                // by its own flag or it would pose as the next prompt.
                if record["isMeta"].as_bool().unwrap_or(false)
                    || record["isCompactSummary"].as_bool().unwrap_or(false)
                    || trimmed.is_empty()
                    || trimmed.starts_with('<')
                {
                    return;
                }
                self.flush_command_turn(out);
                // A turn still open here was never closed by the harness — it
                // outgrew the cap, or the harness died mid-turn. Replacing it
                // drops it whole and resynchronises on this prompt.
                self.open = Some(OpenTurn::opened(text, stamped_ms));
            }
            "assistant" => {
                self.flush_command_turn(out);
                if let Some(open) = self.open.as_mut() {
                    let text = message_text(&record["message"]);
                    if !text.is_empty() {
                        open.push_answer(text);
                    }
                }
            }
            "system" if record["subtype"] == "turn_duration" => {
                self.close(TurnEnd::Normal, out);
            }
            _ => {}
        }
    }

    fn feed_codex(&mut self, record: &Value, out: &mut Vec<Turn>) {
        let payload = &record["payload"];
        let payload_type = payload["type"].as_str().unwrap_or_default();
        let stamped_ms = record_ms(record);
        match record["type"].as_str().unwrap_or_default() {
            "event_msg" => match payload_type {
                // task_started opens the turn before the user message that
                // carries its prompt (measured), so anything still open here is
                // a turn the harness never closed: dropped whole, not carried.
                "task_started" => {
                    self.open = Some(OpenTurn {
                        start_ms: stamped_ms,
                        ..Default::default()
                    });
                }
                "task_complete" => {
                    if let Some(open) = self.open.as_mut() {
                        // An absent or empty statement leaves the streamed
                        // assistant messages as the only record of the answer.
                        if let Some(stated) = payload["last_agent_message"]
                            .as_str()
                            .filter(|stated| !stated.is_empty())
                        {
                            open.state_answer(stated.to_string());
                        }
                    }
                    self.close(TurnEnd::Normal, out);
                }
                "turn_aborted" => self.close(TurnEnd::Interrupted, out),
                _ => {}
            },
            "response_item" if payload_type == "message" => {
                let text = blocks_text(&payload["content"]);
                match payload["role"].as_str().unwrap_or_default() {
                    "user" => {
                        let open = self.open.get_or_insert_with(|| OpenTurn {
                            start_ms: stamped_ms,
                            ..Default::default()
                        });
                        // The harness sends its own environment block as a user
                        // message; the first plain one is what was typed.
                        if open.prompt.is_empty()
                            && !text.trim_start().starts_with("<environment_context")
                        {
                            open.take_prompt(text);
                        }
                    }
                    "assistant" => {
                        if let Some(open) = self.open.as_mut() {
                            if !text.is_empty() {
                                open.push_answer(text);
                            }
                        }
                    }
                    // developer-role messages are harness instructions.
                    _ => {}
                }
            }
            _ => {}
        }
    }
}

// ---------------------------------------------------------------------------
// Record reading
// ---------------------------------------------------------------------------

/// Epoch milliseconds the harness stamped on a record. Both layouts carry the
/// instant at the top level; a record without a readable one yields 0, and a
/// turn opened on such a record holds no temporal evidence, which the matcher
/// requires — so it can never be tied to a submit.
fn record_ms(record: &Value) -> i64 {
    record["timestamp"]
        .as_str()
        .and_then(session_log::parse_iso_ms)
        .unwrap_or(0)
}

/// Text of a message whose content is either a plain string or content blocks.
fn message_text(message: &Value) -> String {
    match &message["content"] {
        Value::String(text) => text.clone(),
        blocks => blocks_text(blocks),
    }
}

/// Concatenate the `text` of every content block. Tool blocks keep their
/// payload under other keys, so they contribute nothing.
fn blocks_text(content: &Value) -> String {
    let Some(blocks) = content.as_array() else {
        return String::new();
    };
    blocks
        .iter()
        .filter_map(|block| block["text"].as_str())
        .collect()
}

fn has_tool_result(message: &Value) -> bool {
    message["content"]
        .as_array()
        .is_some_and(|blocks| blocks.iter().any(|block| block["type"] == "tool_result"))
}

/// Where a claude record keeps slash-command tags: `message.content` on a user
/// record, top-level `content` on a system/local_command record.
fn claude_tagged_body(record: &Value) -> String {
    match record["content"].as_str() {
        Some(text) => text.to_string(),
        None => message_text(&record["message"]),
    }
}

/// Body of the first `<tag>…</tag>` pair, trimmed.
fn tag_body(text: &str, tag: &str) -> Option<String> {
    let opening = format!("<{tag}>");
    let closing = format!("</{tag}>");
    let start = text.find(&opening)? + opening.len();
    let end = start + text[start..].find(&closing)?;
    Some(text[start..end].trim().to_string())
}
