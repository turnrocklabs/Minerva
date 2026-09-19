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

use crate::session_log::{self, TerminalFacts};

/// Prompts retained per terminal. The binder reads only the latest one; the
/// history is what lets the answer matcher restate the submit instant of a
/// prompt whose turn finished a few sends ago, and what the backfill's search
/// cap watches for change.
pub const MAX_PROMPTS: usize = 8;

/// One prompt body the relay submitted, and when it submitted it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Prompt {
    pub text: String,
    /// Epoch milliseconds at submit time, 0 when unknown (a state file written
    /// before the field existed). The matcher requires a real instant to tie a
    /// log turn to this prompt, so 0 means the screen text stands — an invented
    /// value would tie it to whatever turn happened to be near.
    pub submitted_ms: i64,
}

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
    /// Prompts the relay submitted into the terminal, oldest first.
    pub prompts: VecDeque<Prompt>,
}

impl SessionFacts {
    /// Append a submitted prompt, dropping the oldest past MAX_PROMPTS.
    /// Empty bodies are not prompts (a bare Enter selecting a chooser row).
    pub fn record_prompt(&mut self, text: &str, submitted_ms: i64) {
        if text.is_empty() {
            return;
        }
        self.prompts.push_back(Prompt {
            text: text.to_string(),
            submitted_ms,
        });
        while self.prompts.len() > MAX_PROMPTS {
            self.prompts.pop_front();
        }
    }

    /// When the relay last submitted `text`, or 0 when it is not retained.
    /// The LATEST submission wins: a prompt sent twice names the turn just
    /// driven, not the earlier one it repeats.
    pub fn submitted_ms(&self, text: &str) -> i64 {
        self.prompts
            .iter()
            .rev()
            .find(|p| session_log::prompt_matches(text, &p.text))
            .map(|p| p.submitted_ms)
            .unwrap_or(0)
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
    /// where any invented value would prune the right file. Only the latest
    /// prompt is handed over, with its submit instant: the binder matches on
    /// that one alone.
    pub fn to_terminal_facts(&self, profile_id: &str) -> TerminalFacts {
        let current = self.prompts.back();
        TerminalFacts {
            profile_id: profile_id.to_string(),
            cwd: self.cwd.as_deref().map(PathBuf::from),
            window_start_ms: self.start_ms.unwrap_or(0),
            window_end_ms: None,
            current_prompt: current.map(|p| p.text.clone()),
            current_submitted_ms: current.map_or(0, |p| p.submitted_ms),
        }
    }

    /// Merge the facts into a persisted session object. Submit times go in a
    /// second array aligned by index with the prompt bodies, so a relay that
    /// predates them still reads the prompts it knows.
    pub fn write_into(&self, obj: &mut Map<String, Value>) {
        obj.insert("cwd".to_string(), json!(self.cwd));
        obj.insert("start_ms".to_string(), json!(self.start_ms));
        let texts: Vec<&str> = self.prompts.iter().map(|p| p.text.as_str()).collect();
        obj.insert("prompts".to_string(), json!(texts));
        let times: Vec<i64> = self.prompts.iter().map(|p| p.submitted_ms).collect();
        obj.insert("prompt_ms".to_string(), json!(times));
    }

    /// Read the facts back out of a persisted session object. A file written
    /// by a relay that predates these fields yields absent facts, not an error.
    pub fn from_json(obj: &Value) -> Self {
        // Read the times before the bodies so a body dropped as empty cannot
        // shift every later prompt onto the wrong time.
        let times: Vec<i64> = obj
            .get("prompt_ms")
            .and_then(|v| v.as_array())
            .map(|items| items.iter().map(|v| v.as_i64().unwrap_or(0)).collect())
            .unwrap_or_default();
        let prompts: VecDeque<Prompt> = obj
            .get("prompts")
            .and_then(|v| v.as_array())
            .map(|items| {
                items
                    .iter()
                    .enumerate()
                    .filter_map(|(i, p)| {
                        p.as_str().filter(|p| !p.is_empty()).map(|text| Prompt {
                            text: text.to_string(),
                            submitted_ms: times.get(i).copied().unwrap_or(0),
                        })
                    })
                    .collect::<Vec<Prompt>>()
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
        facts.record_prompt("", 10);
        for i in 0..MAX_PROMPTS + 3 {
            facts.record_prompt(&format!("prompt {i}"), 1_000 + i as i64);
        }
        assert_eq!(facts.prompts.len(), MAX_PROMPTS, "bounded at MAX_PROMPTS");
        assert_eq!(
            facts.prompts.front().unwrap().text,
            "prompt 3",
            "oldest dropped"
        );
        assert_eq!(
            facts.prompts.back().unwrap().text,
            format!("prompt {}", MAX_PROMPTS + 2),
            "newest kept"
        );
        assert_eq!(facts.submitted_ms("prompt 3"), 1_003);
        assert_eq!(
            facts.submitted_ms("  prompt 3  "),
            1_003,
            "matched the way the binder matches prompts"
        );
        assert_eq!(
            facts.submitted_ms("prompt 0"),
            0,
            "an aged-out prompt has no submit time, so no log turn can be tied to it"
        );
    }

    #[test]
    fn a_repeated_prompt_reports_its_latest_submission() {
        let mut facts = SessionFacts::default();
        facts.record_prompt("continue", 5_000);
        facts.record_prompt("something else", 6_000);
        facts.record_prompt("continue", 7_000);
        assert_eq!(facts.submitted_ms("continue"), 7_000);
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
        facts.record_prompt("first", 1_600_000_001_000);
        facts.record_prompt("second", 1_600_000_002_000);

        let mut obj = Map::new();
        obj.insert("terminal_id".to_string(), json!("t-1"));
        facts.write_into(&mut obj);
        assert_eq!(obj["prompts"], json!(["first", "second"]));
        assert_eq!(SessionFacts::from_json(&Value::Object(obj)), facts);

        let legacy = json!({"terminal_id": "t-1", "profile_id": "claude"});
        assert_eq!(SessionFacts::from_json(&legacy), SessionFacts::default());

        // A file from a relay that wrote prompts but no submit times.
        let untimed = json!({
            "terminal_id": "t-1",
            "cwd": "/work/proj",
            "prompts": ["first", "second"],
        });
        let loaded = SessionFacts::from_json(&untimed);
        assert_eq!(loaded.prompts.len(), 2);
        assert_eq!(loaded.submitted_ms("second"), 0, "unknown, not invented");
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
