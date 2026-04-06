# Design: Tool Facades — One Meta-Tool Per Family

**Status:** Draft  
**Date:** 2026-04-06  
**Author:** Internal design spike

---

## 1. Problem Statement

Minerva's MCP server registers tools individually, one per action. At current counts:

| Family       | Tools registered | Approx tokens per tool | Family total |
|--------------|-----------------|------------------------|--------------|
| cobrowser    | 20              | ~155                   | ~3,100       |
| spreadsheet  | 20              | ~145                   | ~2,900       |
| terminal     | 6               | ~140                   | ~840         |
| other        | ~10             | ~130                   | ~1,300       |
| **Total**    | **~56**         |                        | **~8,140**   |

The tools array is sent with **every API request**. At ~45 activated tools the schemas alone consume roughly 7,000 tokens — approximately 86% of a short context window before the system prompt and conversation are counted. This is dead weight on every call, even when only one or two tool families are actually needed.

Secondary issues:
- The list of tool names leaks into skill instructions and prompts, creating tight coupling.
- Adding a new action requires a new top-level tool registration, growing the array further.

---

## 2. Proposed Solution: Facade Meta-Tools

Replace each family's N individual tools with a single facade tool that takes an `action` discriminator and an open `params` object. Internal dispatch is unchanged — the facade is a thin routing layer in front of existing handlers.

```
LLM call  ──>  cobrowser { action: "navigate", params: { url: "…" } }
                    │
              FacadeRouter
                    │
              _handle_cobrowser_navigate(params)   ← existing handler, unmodified
```

One facade replaces the entire family in the MCP tools array. The schema shrinks from ~3,100 tokens to ~80 tokens for cobrowser — a **~97% reduction per family**.

---

## 3. Token Savings Analysis

| Family      | Before (tokens) | After (tokens) | Saved   |
|-------------|----------------|----------------|---------|
| cobrowser   | ~3,100         | ~80            | ~3,020  |
| spreadsheet | ~2,900         | ~80            | ~2,820  |
| terminal    | ~840           | ~60            | ~780    |
| **Total**   | **~6,840**     | **~220**       | **~6,620** |

Estimated per-session savings at 200 turns: **~1.3M tokens** in tool schema overhead alone, translating to meaningful cost and latency reductions for long agentic sessions.

---

## 4. Facade Schema Sketches

### 4.1 cobrowser

```json
{
  "name": "cobrowser",
  "description": "Browser automation via Firefox extension. action must be one of the enum values; params are action-specific (see skill instructions for field details).\n\nActions: navigate(url), read(selector), click(selector), rightclick(selector), doubleclick(selector), type(selector,text,clear?), scroll(direction,amount?,selector?), query_all(selector,limit?), page_identity(), page_structure(), page_section(selector,fields?), page_html(), screenshot(), tab_list(), tab_new(url?), tab_close(tab_id), tab_claim(tab_id), tab_release(tab_id), native_click(x,y), native_type(text), native_scroll(direction,amount), native_hotkey(keys), native_move(x,y), drag(from_x,from_y,to_x,to_y), delay(ms), request_human(reason,message), get_user_requests(), clear_user_request(id)",
  "inputSchema": {
    "type": "object",
    "properties": {
      "action": {
        "type": "string",
        "enum": ["navigate","read","click","rightclick","doubleclick","type","scroll","query_all","page_identity","page_structure","page_section","page_html","screenshot","tab_list","tab_new","tab_close","tab_claim","tab_release","native_click","native_type","native_scroll","native_hotkey","native_move","drag","delay","request_human","get_user_requests","clear_user_request"]
      },
      "params": {
        "type": "object",
        "description": "Action-specific parameters. See skill instructions for per-action fields."
      }
    },
    "required": ["action"]
  }
}
```

### 4.2 spreadsheet

```json
{
  "name": "spreadsheet",
  "description": "Spreadsheet editor operations.\n\nActions: get_data(editor_id), update_data(editor_id,data), add_row(editor_id,data?), delete_row(editor_id,row), insert_row(editor_id,row,data?), add_column(editor_id,name,type?), delete_column(editor_id,col), insert_column(editor_id,col,name), set_cell_formula(editor_id,row,col,formula), fill_down(editor_id,row,col,count), format_cells(editor_id,range,format), set_column_width(editor_id,col,width), set_row_height(editor_id,row,height), recalculate(editor_id), undo(editor_id), redo(editor_id), get_history(editor_id), link_to_note(editor_id,note_id), create(title?)",
  "inputSchema": {
    "type": "object",
    "properties": {
      "action": {
        "type": "string",
        "enum": ["get_data","update_data","add_row","delete_row","insert_row","add_column","delete_column","insert_column","set_cell_formula","fill_down","format_cells","set_column_width","set_row_height","recalculate","undo","redo","get_history","link_to_note","create"]
      },
      "params": {
        "type": "object",
        "description": "Action-specific parameters."
      }
    },
    "required": ["action"]
  }
}
```

### 4.3 terminal

```json
{
  "name": "terminal",
  "description": "PTY terminal control. Use \\r (not \\n) to submit commands.\n\nActions: list(), create(title?), close(terminal_id), read(terminal_id,mode?), write(terminal_id,text), wait(terminal_id,timeout_ms?,settle_ms?)",
  "inputSchema": {
    "type": "object",
    "properties": {
      "action": {
        "type": "string",
        "enum": ["list","create","close","read","write","wait"]
      },
      "params": {
        "type": "object",
        "description": "Action-specific parameters."
      }
    },
    "required": ["action"]
  }
}
```

---

## 5. Internal Dispatch

The facade handler receives `(action, params)` and routes by action name. No existing handler changes.

```gdscript
# Pseudocode — MinervaMCPServer.gd
func _handle_cobrowser(args: Dictionary) -> Variant:
    var action: String = args.get("action", "")
    var params: Dictionary = args.get("params", {})
    match action:
        "navigate":   return _handle_cobrowser_navigate(params)
        "read":       return _handle_cobrowser_read(params)
        "click":      return _handle_cobrowser_click(params)
        "scroll":     return _handle_cobrowser_scroll(params)
        # … all other actions …
        _:
            return { "error": "Unknown cobrowser action: " + action }
```

The action-to-handler mapping is a straightforward string match. Error handling for unknown actions returns a structured error the LLM can act on (retry with corrected action name).

---

## 6. Tradeoffs

### Pros
- **Massive token savings** (~6,600 tokens per request eliminated from the tools array).
- **Simpler tool list for the LLM** — fewer names to reason about, less confusion between similarly-named tools.
- **Easier to extend** — new actions added to description and dispatch table, not as new top-level tools.
- **Cleaner skill instructions** — skills reference one tool name, not 20.

### Cons
- **No per-action parameter schema validation** — the MCP layer cannot enforce that `navigate` requires `url`. Mistakes surface at runtime rather than at schema-validation time. Mitigation: clear descriptions + skill instructions, and runtime error messages that name the missing field.
- **Breaking change for existing prompts and skills** — any skill or system prompt that calls `cobrowser_navigate(url=…)` by the old tool name will fail. All callers must be updated.
- **Harder to introspect in tooling** — MCP clients that display per-tool docs lose the per-action detail; it moves into the description string.
- **Single failure surface** — a bug in the facade router can silently misdispatch; individual tools fail independently.

---

## 7. Migration Path

1. **Phase 1 — Opt-in facade mode.** Add a `facade_mode: bool` flag to the MCP server config (or per tool-set). When enabled, register facades instead of individual tools. Individual tools remain available for interactive/non-agent sessions.

2. **Phase 2 — Skill instruction updates.** For each family, update skill instruction files to use the facade calling convention. Keep a compatibility shim that maps old individual tool names to facade calls for a transition period.

3. **Phase 3 — Default facade for agentic sessions.** Once skills are updated and tested, make facade mode the default for agent spawns. Individual tools become the opt-in for backwards compat.

4. **Phase 4 — Deprecate individual registrations.** Remove individual tool registrations from the default tool-set; keep them available as a legacy tool-set that can be explicitly enabled.

---

## 8. Recommendation

**Implement, starting with cobrowser and terminal.**

Cobrowser delivers the largest single saving (~3,020 tokens) and its actions are already documented in a skill file, making the description migration straightforward. Terminal is small but high-frequency in agentic sessions and the six-tool-to-one consolidation is obvious.

Spreadsheet is the most complex family (formula engine, undo/redo, multi-editor targeting) and its per-action parameter shapes vary most. Do it second, after the facade pattern is proven with the simpler families.

The breaking-change risk is real but manageable: Minerva's skill system is the primary call site, and skills are versioned text files. A one-time update pass across affected skill files is a bounded task. Gate the change behind `facade_mode` from day one so rollback is a config flip, not a code revert.

Do **not** apply facades to singleton tools (docket, nudge, PCB) — those families are small enough that the overhead is negligible and the per-tool schema validation is genuinely useful.
