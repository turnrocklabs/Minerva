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
// Turn boundaries (measured against Claude Code 2.1.277 and codex-cli 0.155.1):
//   claude — a turn opens at a user record carrying typed text and closes at
//            the first system/turn_duration record (normal) or at the user
//            record reading "[Request interrupted by user]" (interrupted). No
//            turn_duration follows an interrupt. The harness can write several
//            turn_duration records between two prompts, one per non-user
//            trigger (task notifications, queued messages); cutting at the
//            first keeps a turn to the work its own prompt started.
//   codex  — a turn opens at event_msg task_started and closes at task_complete
//            (normal) or turn_aborted (interrupted).
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

// Nothing calls the extractor yet; drop this when it joins the turn path.
#![allow(dead_code)]

use std::fs::File;
use std::io::{self, BufRead, BufReader, Seek, SeekFrom};
use std::path::Path;

use serde_json::Value;

/// The whole text of the claude record that marks an aborted response.
const CLAUDE_INTERRUPT: &str = "[Request interrupted by user]";

/// Separator between the text pieces of one answer or one prompt.
const PIECE_JOIN: &str = "\n\n";

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
    pub end: TurnEnd,
    pub slash_commands: Vec<SlashCommand>,
}

/// Position in the log that the next extraction resumes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Cursor {
    pub offset: u64,
}

impl Cursor {
    pub fn start() -> Cursor {
        Cursor { offset: 0 }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Extraction {
    pub turns: Vec<Turn>,
    pub cursor: Cursor,
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/// Read the turns that completed after `cursor`, and where to resume.
pub fn extract(path: &Path, harness: Harness, cursor: Cursor) -> io::Result<Extraction> {
    let mut file = File::open(path)?;
    // A file shorter than the cursor was rotated or rewritten, so the old
    // offset names nothing in the bytes that are there now.
    let start = if cursor.offset > file.metadata()?.len() {
        0
    } else {
        cursor.offset
    };
    file.seek(SeekFrom::Start(start))?;
    let mut reader = BufReader::new(file);

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
        }
        if extractor.is_idle() {
            committed = position;
        }
    }

    Ok(Extraction {
        turns,
        cursor: Cursor { offset: committed },
    })
}

/// A turn being built up, before its end marker is known.
#[derive(Default)]
struct OpenTurn {
    prompt: String,
    answer_parts: Vec<String>,
    /// The answer the harness states for itself, which wins over the parts.
    stated_answer: Option<String>,
    slash_commands: Vec<SlashCommand>,
    /// True while the turn exists only to carry a slash command, which no
    /// end marker of its own ever closes.
    command_only: bool,
}

impl OpenTurn {
    fn finish(self, end: TurnEnd) -> Turn {
        let answer = self
            .stated_answer
            .unwrap_or_else(|| self.answer_parts.join(PIECE_JOIN));
        Turn {
            prompt: self.prompt,
            answer,
            end,
            slash_commands: self.slash_commands,
        }
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
        if let Some(open) = self.open.take() {
            out.push(open.finish(end));
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
    fn attach_command(&mut self, command: SlashCommand, out: &mut Vec<Turn>) {
        self.flush_command_turn(out);
        match self.open.as_mut() {
            Some(open) => open.slash_commands.push(command),
            None => {
                let mut prompt = command.name.clone();
                if !command.args.is_empty() {
                    prompt.push(' ');
                    prompt.push_str(&command.args);
                }
                self.open = Some(OpenTurn {
                    prompt,
                    slash_commands: vec![command],
                    command_only: true,
                    ..Default::default()
                });
            }
        }
    }

    fn feed_claude(&mut self, record: &Value, out: &mut Vec<Turn>) {
        let kind = record["type"].as_str().unwrap_or_default();
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
                out,
            );
            return;
        }
        if let Some(stdout) = tag_body(&tagged, "local-command-stdout") {
            let mut command_turn_done = false;
            if let Some(open) = self.open.as_mut() {
                if let Some(command) = open.slash_commands.last_mut() {
                    command.stdout = stdout;
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
                if trimmed == CLAUDE_INTERRUPT {
                    self.close(TurnEnd::Interrupted, out);
                    return;
                }
                // isMeta rows and tag-wrapped scaffolding are the harness
                // talking to itself, not anything the user typed.
                if record["isMeta"].as_bool().unwrap_or(false)
                    || trimmed.is_empty()
                    || trimmed.starts_with('<')
                {
                    return;
                }
                self.flush_command_turn(out);
                // A prompt re-recorded or queued inside an open turn does not
                // start a second one; the turn keeps the prompt it opened with.
                if self.open.is_none() {
                    self.open = Some(OpenTurn {
                        prompt: text,
                        ..Default::default()
                    });
                }
            }
            "assistant" => {
                self.flush_command_turn(out);
                if let Some(open) = self.open.as_mut() {
                    let text = message_text(&record["message"]);
                    if !text.is_empty() {
                        open.answer_parts.push(text);
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
        match record["type"].as_str().unwrap_or_default() {
            "event_msg" => match payload_type {
                "task_started" => {
                    if self.open.is_none() {
                        self.open = Some(OpenTurn::default());
                    }
                }
                "task_complete" => {
                    if let Some(open) = self.open.as_mut() {
                        // An absent or empty statement leaves the streamed
                        // assistant messages as the only record of the answer.
                        open.stated_answer = payload["last_agent_message"]
                            .as_str()
                            .filter(|stated| !stated.is_empty())
                            .map(str::to_string);
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
                        let open = self.open.get_or_insert_with(OpenTurn::default);
                        // The harness sends its own environment block as a user
                        // message; the first plain one is what was typed.
                        if open.prompt.is_empty()
                            && !text.trim_start().starts_with("<environment_context")
                        {
                            open.prompt = text;
                        }
                    }
                    "assistant" => {
                        if let Some(open) = self.open.as_mut() {
                            if !text.is_empty() {
                                open.answer_parts.push(text);
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
