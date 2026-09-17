// filter_rules.rs — per-session named chrome-filter rules for agent-relay.
//
// Rules are installed by the LLM caller via filter_set and applied by
// read_clean after the built-in chrome filter pass (DCR #464). Each rule
// has a name (unique key), a validated regex pattern, an action, and an
// optional replacement string.
//
// Design:
//   - Rules are held in a BTreeMap (ordered by insertion name for stable listing).
//   - Regex validation happens at set time; bad patterns produce a clear error
//     before the rule is stored.
//   - The FilterRuleSet is stored as a global Mutex<FilterRuleSet> in main.rs
//     so all tool handlers share one set.
//
// Two actions are supported:
//   drop_line  — if the regex matches anywhere in the line, discard the whole line.
//   replace    — replace every match in the line with `replacement` (or "" if absent).
//
// Note: the manifest previously declared action "strip_match" which is the same
// semantic as "replace" with an empty replacement. Both are accepted (strip_match
// is treated as replace with ""). The canonical name going forward is "replace".

use std::collections::BTreeMap;
use serde::{Deserialize, Serialize};
use regex::Regex;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// The action to take when a rule's pattern matches a line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuleAction {
    /// Drop the entire line if the pattern matches anywhere in it.
    DropLine,
    /// Replace every occurrence of the pattern with `replacement` (default "").
    Replace,
    /// Alias for Replace("") — accepted for backwards compat with early B1 manifest.
    StripMatch,
}

/// A single named filter rule, ready to apply.
#[derive(Debug, Clone, Serialize)]
pub struct FilterRule {
    /// Unique name / key for this rule.
    pub name: String,
    /// Original pattern string (stored for serialization / filter_list).
    pub pattern: String,
    /// Action to take on match.
    pub action: RuleAction,
    /// Replacement string (used for Replace/StripMatch; empty string if absent).
    pub replacement: String,
    /// Compiled regex — not serialized.
    #[serde(skip)]
    pub regex: Regex,
}

/// A serialisation-friendly view of a FilterRule (no compiled regex).
#[derive(Debug, Serialize)]
pub struct FilterRuleView<'a> {
    pub name: &'a str,
    pub pattern: &'a str,
    pub action: &'a RuleAction,
    pub replacement: &'a str,
}

impl FilterRule {
    /// Attempt to construct a FilterRule, compiling the regex.
    /// Returns Err with a human-readable message on bad regex.
    pub fn new(
        name: impl Into<String>,
        pattern: impl Into<String>,
        action: RuleAction,
        replacement: impl Into<String>,
    ) -> Result<Self, String> {
        let name = name.into();
        let pattern = pattern.into();
        let replacement = replacement.into();

        let regex = Regex::new(&pattern)
            .map_err(|e| format!("invalid regex pattern '{}': {}", pattern, e))?;

        Ok(FilterRule { name, pattern, action, replacement, regex })
    }

    /// Apply this rule to a single line.
    /// Returns Some(new_line) or None if the line should be dropped.
    pub fn apply<'a>(&self, line: &'a str) -> Option<String> {
        match self.action {
            RuleAction::DropLine => {
                if self.regex.is_match(line) {
                    None // drop
                } else {
                    Some(line.to_string())
                }
            }
            RuleAction::Replace | RuleAction::StripMatch => {
                let replaced = self.regex.replace_all(line, self.replacement.as_str());
                Some(replaced.into_owned())
            }
        }
    }

    /// Serialisable view (omits the compiled regex).
    pub fn view(&self) -> FilterRuleView<'_> {
        FilterRuleView {
            name: &self.name,
            pattern: &self.pattern,
            action: &self.action,
            replacement: &self.replacement,
        }
    }
}

// ---------------------------------------------------------------------------
// Rule set
// ---------------------------------------------------------------------------

/// The ordered collection of named filter rules held in worker state.
#[derive(Debug, Default)]
pub struct FilterRuleSet {
    /// BTreeMap keeps rules in name-sorted order for stable filter_list output.
    rules: BTreeMap<String, FilterRule>,
}

impl FilterRuleSet {
    pub fn new() -> Self {
        Self { rules: BTreeMap::new() }
    }

    /// Insert or replace a rule. Returns Ok(was_update) where was_update is true
    /// if a rule with the same name already existed.
    pub fn set(&mut self, rule: FilterRule) -> bool {
        let existed = self.rules.contains_key(&rule.name);
        self.rules.insert(rule.name.clone(), rule);
        existed
    }

    /// Delete a rule by name. Returns true if it existed.
    pub fn delete(&mut self, name: &str) -> bool {
        self.rules.remove(name).is_some()
    }

    /// Iterate rules in name order.
    pub fn iter(&self) -> impl Iterator<Item = &FilterRule> {
        self.rules.values()
    }

    /// Number of installed rules.
    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.rules.len()
    }

    /// Apply all rules to `text`, returning the filtered result.
    /// Rules are applied in BTreeMap key order (alphabetical by name).
    pub fn apply(&self, text: &str) -> String {
        if self.rules.is_empty() {
            return text.to_string();
        }
        let ends_with_newline = text.ends_with('\n');
        let mut result = String::with_capacity(text.len());
        for line in text.lines() {
            let mut current: Option<String> = Some(line.to_string());
            for rule in self.rules.values() {
                current = match current {
                    None => None, // already dropped by an earlier rule
                    Some(l) => rule.apply(&l),
                };
                if current.is_none() {
                    break;
                }
            }
            if let Some(kept) = current {
                result.push_str(&kept);
                result.push('\n');
            }
        }
        // Restore trailing-newline contract.
        if !ends_with_newline && result.ends_with('\n') {
            result.truncate(result.len() - 1);
        }
        result
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn make_rule(name: &str, pattern: &str, action: RuleAction, replacement: &str) -> FilterRule {
        FilterRule::new(name, pattern, action, replacement).expect("valid rule")
    }

    // ── FilterRule::new ──────────────────────────────────────────────────────

    #[test]
    fn test_new_valid_regex() {
        let r = FilterRule::new("r1", r"\bfoo\b", RuleAction::DropLine, "");
        assert!(r.is_ok(), "valid regex should succeed");
    }

    #[test]
    fn test_new_invalid_regex_returns_err() {
        let r = FilterRule::new("r1", r"[invalid(", RuleAction::DropLine, "");
        assert!(r.is_err(), "invalid regex should fail");
        let msg = r.unwrap_err();
        assert!(msg.contains("invalid regex pattern"), "error should mention pattern: {msg}");
    }

    // ── FilterRule::apply — drop_line ────────────────────────────────────────

    #[test]
    fn test_drop_line_matches() {
        let rule = make_rule("spinner", r"^⠿", RuleAction::DropLine, "");
        assert_eq!(rule.apply("⠿ Thinking…"), None, "matching line dropped");
    }

    #[test]
    fn test_drop_line_no_match() {
        let rule = make_rule("spinner", r"^⠿", RuleAction::DropLine, "");
        assert_eq!(
            rule.apply("Normal content line"),
            Some("Normal content line".to_string()),
            "non-matching line kept"
        );
    }

    // ── FilterRule::apply — replace ─────────────────────────────────────────

    #[test]
    fn test_replace_removes_matched_portion() {
        // The middle-dot · is U+00B7 — not ASCII whitespace. Use a literal.
        // Numbers use space as thousand separator (e.g. "24 103") so match
        // the whole context trailer with a broad "non-newline chars" pattern.
        let rule = make_rule("strip_ctx", r"\s*·\s*context [^\n]+", RuleAction::Replace, "");
        let input = "claude-sonnet-4-6 · context 24 103 / 200 000";
        let out = rule.apply(input).unwrap();
        assert_eq!(out, "claude-sonnet-4-6", "replacement removes context portion");
    }

    #[test]
    fn test_replace_with_replacement_string() {
        let rule = make_rule("redact", r"\d{4}", RuleAction::Replace, "XXXX");
        let out = rule.apply("PIN is 1234 or 5678").unwrap();
        assert_eq!(out, "PIN is XXXX or XXXX", "digits replaced with XXXX");
    }

    // ── FilterRule::apply — strip_match (alias) ──────────────────────────────

    #[test]
    fn test_strip_match_alias_removes_match() {
        let rule = make_rule("sm", r"\bTODO\b", RuleAction::StripMatch, "");
        let out = rule.apply("TODO fix this").unwrap();
        assert_eq!(out, " fix this", "StripMatch removes the match, keeps rest");
    }

    // ── FilterRuleSet ────────────────────────────────────────────────────────

    #[test]
    fn test_set_and_delete() {
        let mut rs = FilterRuleSet::new();
        let r = make_rule("r1", "foo", RuleAction::DropLine, "");
        assert!(!rs.set(r), "first set returns false (not an update)");
        assert_eq!(rs.len(), 1);

        let r2 = make_rule("r1", "bar", RuleAction::DropLine, "");
        assert!(rs.set(r2), "second set with same name returns true (update)");
        assert_eq!(rs.len(), 1, "update does not add a new entry");

        assert!(rs.delete("r1"), "delete existing returns true");
        assert!(!rs.delete("r1"), "delete non-existent returns false");
        assert_eq!(rs.len(), 0);
    }

    #[test]
    fn test_apply_empty_ruleset_returns_input() {
        let rs = FilterRuleSet::new();
        let text = "hello\nworld\n";
        assert_eq!(rs.apply(text), text);
    }

    #[test]
    fn test_apply_drop_rule() {
        let mut rs = FilterRuleSet::new();
        rs.set(make_rule("drop_spinner", r"^⠿", RuleAction::DropLine, ""));
        let input = "Line A\n⠿ Thinking…\nLine B\n";
        let out = rs.apply(input);
        assert!(out.contains("Line A"), "content kept");
        assert!(out.contains("Line B"), "content kept");
        assert!(!out.contains("Thinking"), "spinner line dropped");
    }

    #[test]
    fn test_apply_replace_rule() {
        let mut rs = FilterRuleSet::new();
        rs.set(make_rule("mask_num", r"\d+", RuleAction::Replace, "#"));
        let input = "Found 42 issues in 3 files\n";
        let out = rs.apply(input);
        assert_eq!(out, "Found # issues in # files\n");
    }

    #[test]
    fn test_apply_multiple_rules_ordered() {
        // Both rules apply: first drop_spinner on braille lines, then replace numbers.
        let mut rs = FilterRuleSet::new();
        rs.set(make_rule("a_spinner", r"^⠿", RuleAction::DropLine, ""));
        rs.set(make_rule("b_nums", r"\d+", RuleAction::Replace, "N"));
        let input = "Found 42 items\n⠿ Working…\nDone in 3s\n";
        let out = rs.apply(input);
        assert!(!out.contains("Working"), "spinner dropped by rule a");
        assert_eq!(out, "Found N items\nDone in Ns\n");
    }

    #[test]
    fn test_apply_preserves_trailing_newline_contract() {
        let mut rs = FilterRuleSet::new();
        rs.set(make_rule("r", "x", RuleAction::Replace, "y"));
        // With trailing newline.
        assert!(rs.apply("axb\n").ends_with('\n'), "trailing newline preserved");
        // Without trailing newline.
        assert!(!rs.apply("axb").ends_with('\n'), "no trailing newline preserved");
    }
}
