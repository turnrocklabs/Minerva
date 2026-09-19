// terminal_facts.rs — the per-terminal facts the session-log binder needs,
// in the form the watch registry holds and the state file persists.
//
// The binder re-derives a terminal's harness transcript from facts alone, so
// every field here must survive a relay restart: cwd and creation time come
// from the host's terminal listing, the prompts from the relay's own send
// path. Nothing is inferred — an unknown cwd stays None so the binder widens
// its search instead of pruning by a guess.

use std::collections::VecDeque;
use std::path::PathBuf;

use serde_json::{json, Map, Value};

use crate::session_log::TerminalFacts;

/// Prompts retained per terminal. Binding requires EVERY retained prompt to be
/// present in a candidate transcript, so prompts predating a harness `/clear`
/// (which opens a new log file) turn a correct bind into NoLog until they age
/// out — that caps the useful depth. Below the cap, each extra prompt
/// separates sibling sessions sharing one cwd and time window.
pub const MAX_PROMPTS: usize = 8;

/// What a watch session knows about its terminal beyond profile and notify
/// mode. Held in the registry, mirrored into the state file, convertible to
/// the binder's input without adding meaning.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SessionFacts {
    /// Working directory the terminal's child was launched in. None when the
    /// host does not know it.
    pub cwd: Option<String>,
    /// Terminal creation time in epoch milliseconds, as the host reports it.
    pub start_ms: Option<i64>,
    /// Prompt bodies the relay submitted into the terminal, oldest first.
    pub prompts: VecDeque<String>,
}

impl SessionFacts {
    /// Append a submitted prompt, dropping the oldest past MAX_PROMPTS.
    /// Empty bodies are not prompts (a bare Enter selecting a chooser row).
    pub fn record_prompt(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        self.prompts.push_back(text.to_string());
        while self.prompts.len() > MAX_PROMPTS {
            self.prompts.pop_front();
        }
    }

    /// Take cwd and creation time from one `host.terminal.list` entry, filling
    /// only what is still unknown: a host that predates these fields reports
    /// neither, and must not erase what the state file restored. Returns true
    /// when something was learned.
    pub fn adopt_listing(&mut self, entry: &Value) -> bool {
        let mut learned = false;
        if self.cwd.is_none() {
            if let Some(cwd) = entry.get("cwd").and_then(|v| v.as_str()) {
                if !cwd.is_empty() {
                    self.cwd = Some(cwd.to_string());
                    learned = true;
                }
            }
        }
        if self.start_ms.is_none() {
            if let Some(ms) = entry.get("created_at_ms").and_then(|v| v.as_i64()) {
                self.start_ms = Some(ms);
                learned = true;
            }
        }
        learned
    }

    /// The binder's input for a terminal that is still being watched.
    /// An unknown creation time becomes 0 — a lower bound that prunes nothing,
    /// where any invented value would prune the right file.
    // Reached once the binder joins the turn path; drop the allow then.
    #[allow(dead_code)]
    pub fn to_terminal_facts(&self, profile_id: &str) -> TerminalFacts {
        TerminalFacts {
            profile_id: profile_id.to_string(),
            cwd: self.cwd.as_deref().map(PathBuf::from),
            window_start_ms: self.start_ms.unwrap_or(0),
            window_end_ms: None,
            prompts: self.prompts.iter().cloned().collect(),
        }
    }

    /// Merge the facts into a persisted session object.
    pub fn write_into(&self, obj: &mut Map<String, Value>) {
        obj.insert("cwd".to_string(), json!(self.cwd));
        obj.insert("start_ms".to_string(), json!(self.start_ms));
        let prompts: Vec<&String> = self.prompts.iter().collect();
        obj.insert("prompts".to_string(), json!(prompts));
    }

    /// Read the facts back out of a persisted session object. A file written
    /// by a relay that predates these fields yields absent facts, not an error.
    pub fn from_json(obj: &Value) -> Self {
        let prompts: VecDeque<String> = obj
            .get("prompts")
            .and_then(|v| v.as_array())
            .map(|items| {
                items
                    .iter()
                    .filter_map(|p| p.as_str())
                    .filter(|p| !p.is_empty())
                    .map(str::to_string)
                    .collect::<Vec<String>>()
            })
            .map(|mut v| {
                if v.len() > MAX_PROMPTS {
                    v.drain(..v.len() - MAX_PROMPTS);
                }
                VecDeque::from(v)
            })
            .unwrap_or_default();
        SessionFacts {
            cwd: obj
                .get("cwd")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .map(str::to_string),
            start_ms: obj.get("start_ms").and_then(|v| v.as_i64()),
            prompts,
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompts_are_bounded_and_ordered() {
        let mut facts = SessionFacts::default();
        facts.record_prompt("");
        for i in 0..MAX_PROMPTS + 3 {
            facts.record_prompt(&format!("prompt {i}"));
        }
        assert_eq!(facts.prompts.len(), MAX_PROMPTS, "bounded at MAX_PROMPTS");
        assert_eq!(facts.prompts.front().unwrap(), "prompt 3", "oldest dropped");
        assert_eq!(
            facts.prompts.back().unwrap(),
            &format!("prompt {}", MAX_PROMPTS + 2),
            "newest kept"
        );
    }

    #[test]
    fn listing_fills_only_what_is_unknown() {
        let mut facts = SessionFacts {
            cwd: Some("/restored".to_string()),
            start_ms: None,
            prompts: VecDeque::new(),
        };
        assert!(facts.adopt_listing(&json!({"cwd": "/live", "created_at_ms": 1_700_i64})));
        assert_eq!(
            facts.cwd.as_deref(),
            Some("/restored"),
            "persisted cwd kept"
        );
        assert_eq!(facts.start_ms, Some(1_700));

        let mut blank = SessionFacts::default();
        assert!(!blank.adopt_listing(&json!({"id": "t-1", "cwd": ""})));
        assert_eq!(blank, SessionFacts::default(), "no fields, no facts");
    }

    #[test]
    fn json_round_trip_and_legacy_entry() {
        let mut facts = SessionFacts {
            cwd: Some("/work/proj".to_string()),
            start_ms: Some(1_600_000_000_000),
            ..Default::default()
        };
        facts.record_prompt("first");
        facts.record_prompt("second");

        let mut obj = Map::new();
        obj.insert("terminal_id".to_string(), json!("t-1"));
        facts.write_into(&mut obj);
        assert_eq!(SessionFacts::from_json(&Value::Object(obj)), facts);

        let legacy = json!({"terminal_id": "t-1", "profile_id": "claude"});
        assert_eq!(SessionFacts::from_json(&legacy), SessionFacts::default());
    }

    #[test]
    fn unknown_start_time_prunes_nothing() {
        let facts = SessionFacts::default();
        let bound = facts.to_terminal_facts("claude");
        assert_eq!(bound.window_start_ms, 0);
        assert!(bound.cwd.is_none());
        assert!(bound.window_end_ms.is_none());
    }
}
