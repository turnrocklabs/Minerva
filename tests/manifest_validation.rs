// Integration tests for agent-relay manifest.json correctness.
// Mirrors the pattern from scansort/tests/manifest_validation.rs.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

fn load_manifest() -> serde_json::Value {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("manifest.json");
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("Failed to read manifest.json at {}: {}", path.display(), e));
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("manifest.json is not valid JSON: {}", e))
}

fn tools(manifest: &serde_json::Value) -> &Vec<serde_json::Value> {
    manifest["tools"]
        .as_array()
        .expect("manifest.json must have a top-level 'tools' array")
}

// ── Test 1: every tool has the correct prefix and all names are unique ───────

#[test]
fn test_tool_names_prefix_and_unique() {
    let manifest = load_manifest();
    let tool_list = tools(&manifest);

    let mut seen: HashMap<&str, usize> = HashMap::new();

    for (i, tool) in tool_list.iter().enumerate() {
        let name = tool["name"]
            .as_str()
            .unwrap_or_else(|| panic!("Tool at index {} has no 'name' field", i));

        assert!(
            name.starts_with("minerva_agent_relay_"),
            "Tool at index {} has name '{}' which does not start with 'minerva_agent_relay_'",
            i,
            name
        );

        if let Some(prev) = seen.get(name) {
            panic!("Duplicate tool name '{}' at indices {} and {}", name, prev, i);
        }
        seen.insert(name, i);
    }
}

// ── Test 2: events array declares agent_relay.turn_completed ─────────────────

#[test]
fn test_events_contains_turn_completed() {
    let manifest = load_manifest();

    let events = manifest["events"]
        .as_array()
        .expect("manifest.json must have a top-level 'events' array");

    let has_turn_completed = events
        .iter()
        .any(|e| e["name"].as_str() == Some("agent_relay.turn_completed"));

    assert!(
        has_turn_completed,
        "manifest.json events array must contain 'agent_relay.turn_completed'. \
         Current events: {:?}",
        events.iter().filter_map(|e| e["name"].as_str()).collect::<Vec<_>>()
    );
}

// ── Test 3: required tools are all present ────────────────────────────────────

#[test]
fn test_required_tools_present() {
    let manifest = load_manifest();
    let tool_list = tools(&manifest);

    let required = [
        "minerva_agent_relay_watch_start",
        "minerva_agent_relay_watch_stop",
        "minerva_agent_relay_watch_status",
        "minerva_agent_relay_send",
        "minerva_agent_relay_read_clean",
        "minerva_agent_relay_read_turn",
        "minerva_agent_relay_filter_set",
        "minerva_agent_relay_filter_list",
        "minerva_agent_relay_filter_delete",
        "minerva_agent_relay_profile_get",
        "minerva_agent_relay_profile_set",
        "minerva_agent_relay_profiles_list",
    ];

    for target in &required {
        let found = tool_list.iter().any(|t| t["name"].as_str() == Some(target));
        assert!(found, "Required tool '{}' not found in manifest.json", target);
    }
}

// ── Test 4: tools with required args declare input_schema ────────────────────

#[test]
fn test_tools_with_args_have_input_schema() {
    let manifest = load_manifest();
    let tool_list = tools(&manifest);

    // These tools have required arguments — they must have input_schema.
    let tools_with_required_args = [
        "minerva_agent_relay_watch_start",
        "minerva_agent_relay_watch_stop",
        "minerva_agent_relay_watch_status",
        "minerva_agent_relay_send",
        "minerva_agent_relay_filter_set",
        "minerva_agent_relay_filter_delete",
        "minerva_agent_relay_profile_get",
        "minerva_agent_relay_profile_set",
    ];

    for target in &tools_with_required_args {
        let tool = tool_list
            .iter()
            .find(|t| t["name"].as_str() == Some(target))
            .unwrap_or_else(|| panic!("Tool '{}' not found in manifest.json", target));

        let schema = tool.get("input_schema").unwrap_or_else(|| {
            panic!("Tool '{}' is missing 'input_schema'", target)
        });

        assert_eq!(
            schema["type"].as_str(),
            Some("object"),
            "Tool '{}' input_schema.type must be 'object'",
            target
        );

        // Verify required array exists and is non-empty for tools that have required args.
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(
            required.map(|r| !r.is_empty()).unwrap_or(false),
            "Tool '{}' input_schema.required must be a non-empty array",
            target
        );
    }
}

// ── Test 5: permissions declare required host capabilities ────────────────────

#[test]
fn test_required_host_capabilities_declared() {
    let manifest = load_manifest();

    let caps = manifest["permissions"]["host_capabilities"]
        .as_array()
        .expect("permissions.host_capabilities must be an array");

    let cap_strs: Vec<&str> = caps.iter().filter_map(|v| v.as_str()).collect();

    let required_caps = [
        "host.terminal.list",
        "host.terminal.read",
        "host.terminal.write",
        "host.terminal.wait",
        "host.providers.chat",
    ];

    for cap in &required_caps {
        assert!(
            cap_strs.contains(cap),
            "Required capability '{}' not found in permissions.host_capabilities. \
             Declared: {:?}",
            cap,
            cap_strs
        );
    }
}

// ── Test 6: every manifest tool has a dispatch arm in main.rs ─────────────────

#[test]
fn test_manifest_tools_have_handlers_in_main_rs() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let main_rs_path = manifest_dir.join("src/main.rs");

    let main_rs = match fs::read_to_string(&main_rs_path) {
        Ok(s) => s,
        Err(_) => {
            eprintln!("SKIP test_manifest_tools_have_handlers_in_main_rs: could not read src/main.rs");
            return;
        }
    };

    let manifest = load_manifest();
    let tool_list = tools(&manifest);

    let mut missing: Vec<&str> = Vec::new();

    for tool in tool_list.iter() {
        let name = tool["name"].as_str().expect("tool has name");
        let pattern = format!("\"{}\"", name);
        if !main_rs.contains(&pattern) {
            missing.push(name);
        }
    }

    assert!(
        missing.is_empty(),
        "The following manifest tools have no string literal in src/main.rs dispatch: {:?}",
        missing
    );
}

// ── Test 7: skill entry present with all required fields ─────────────────────

#[test]
fn test_skill_entry_present_with_required_fields() {
    let manifest = load_manifest();

    let skills = manifest.get("skills")
        .and_then(|v| v.as_array())
        .expect("manifest.json must have a 'skills' array");

    assert!(
        !skills.is_empty(),
        "manifest.json skills array must be non-empty (relay skill required)"
    );

    // Required fields per PluginDefinition.REQUIRED_SKILL_FIELDS.
    let required_fields = [
        "id", "title", "summary", "system_prompt", "outcome",
        "preconditions", "steps", "tool_deps", "target",
    ];

    for (i, skill) in skills.iter().enumerate() {
        for field in &required_fields {
            assert!(
                skill.get(field).is_some(),
                "skill[{}] missing required field '{}': {:?}",
                i, field, skill.get("id")
            );
        }

        // id must match ^minerva_agent_relay_[a-z0-9_]+$
        let id = skill["id"].as_str().expect("skill id must be a string");
        assert!(
            id.starts_with("minerva_agent_relay_"),
            "skill id '{}' must start with 'minerva_agent_relay_'",
            id
        );

        // tool_deps must be an array of strings.
        let deps = skill["tool_deps"].as_array()
            .unwrap_or_else(|| panic!("skill '{}' tool_deps must be an array", id));
        for dep in deps {
            assert!(
                dep.as_str().map(|s| !s.is_empty()).unwrap_or(false),
                "skill '{}' tool_deps must be non-empty strings",
                id
            );
        }
    }
}

// ── Test 8: relay skill tool_deps all have valid name format ──────────────────

#[test]
fn test_relay_skill_tool_deps_valid_format() {
    let manifest = load_manifest();

    let skills = manifest["skills"]
        .as_array()
        .expect("skills array");

    let relay_skill = skills.iter()
        .find(|s| s["id"].as_str() == Some("minerva_agent_relay_relay"))
        .expect("minerva_agent_relay_relay skill must be present");

    let deps = relay_skill["tool_deps"]
        .as_array()
        .expect("tool_deps must be an array");

    assert!(!deps.is_empty(), "relay skill must have tool_deps");

    for dep in deps {
        let name = dep.as_str().expect("dep must be a string");
        assert!(!name.is_empty(), "dep must be non-empty");
        // All deps must start with minerva_ (own tools) or be core tool names.
        // Core tool names like minerva_terminal_list, minerva_create_trigger etc. all
        // start with minerva_.
        assert!(
            name.starts_with("minerva_"),
            "tool_dep '{}' must start with 'minerva_' (either plugin or core tool)",
            name
        );
    }

    // Verify the agent_relay tools themselves are in deps.
    let dep_strs: Vec<&str> = deps.iter().filter_map(|d| d.as_str()).collect();
    assert!(dep_strs.contains(&"minerva_agent_relay_send"), "send in deps");
    assert!(dep_strs.contains(&"minerva_agent_relay_read_turn"), "read_turn in deps");
    assert!(dep_strs.contains(&"minerva_agent_relay_watch_start"), "watch_start in deps");
    assert!(dep_strs.contains(&"minerva_create_trigger"), "create_trigger in deps");
}
