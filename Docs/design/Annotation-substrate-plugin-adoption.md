# Annotation Substrate — Plugin Adoption Guide

**Audience:** plugin authors and editor implementors who want to host annotations. **You do not need a Minerva source checkout to read this guide** — every base-class signature, every contract method, and every worked example is reproduced inline. The substrate's surface is small enough that this document is self-contained.
**Sibling:** [`Annotation-substrate-design.md`](./Annotation-substrate-design.md) — the substrate's design contract.

This document teaches the practical side: how to subclass the substrate, register kinds, resolve custom anchors, contribute body views and per-row actions, write authoring tools, opt out of platform rendering, and avoid the off-tree-plugin gotchas. Every code snippet is reproduced from a real implementation; [§13](#13-in-tree-reference-implementations) lists the in-tree files those snippets came from for Minerva maintainers, but plugin authors do not need to consult those files.

---

## 1. Platform vs Plugin Split

The substrate ships a small set of base classes and registries. Plugins contribute concrete subclasses and resolvers. Nothing in the substrate knows what a "PCB net" or "CAD edge" is — that knowledge lives entirely on the plugin side, behind opaque payloads and resolvers.

| Responsibility | Owner | Class / file |
|---|---|---|
| Host base protocol | Substrate | `AnnotationHost` |
| Annotation kind base | Substrate | `AnnotationKind` |
| Authoring tool base | Substrate | `AnnotationAuthorTool` |
| Anchor registry | Substrate | `AnnotationAnchorRegistry` |
| Kind registry | Substrate | `AnnotationRegistry` |
| Schema validator | Substrate | `AnnotationV2Schema` |
| Apply/dry-run wrapper | Substrate | `AnnotationApplyToolRunner` |
| Trust state machine | Substrate | `AnnotationTrustManager` |
| Overlay (Control) | Substrate | `AnnotationOverlay` |
| Workbench (dock pane) | Substrate | `AnnotationWorkbench` |
| Built-in 2D kinds | Core | `BuiltinKinds.register_all(registry)` |
| Concrete `AnnotationHost` subclass | Plugin | e.g. `Helloscene_AnnotationHost`, `Cad_AnnotationHost` |
| Custom `AnnotationKind` subclasses | Plugin | e.g. `cad_edge_number_kind.gd` |
| Custom anchor resolvers | Plugin | callables registered with the host |
| Custom `AnnotationAuthorTool` subclasses | Plugin | e.g. `cad_edge_number_tool.gd` |

The split is enforced two ways:

1. **Namespace.** `AnnotationRegistry.register_annotation_kind` rejects any plugin-owned kind whose name uses the reserved `2d_*` prefix. The convention is `<plugin>_<kind>` for plugin kinds and `2d_<kind>` for core kinds.
2. **Trust.** Plugin contributions (kind renderers, resolvers, apply tools) flow through `AnnotationTrustManager` so a misbehaving plugin auto-suspends without taking the editor down. See [§9](#9-trust-boundary).

---

## 2. Custom Kind Registration

A plugin contributes a kind by subclassing `AnnotationKind`, setting four required identity fields, and overriding the rendering virtuals.

### 2.1 Minimal subclass

```gdscript
extends AnnotationKind

func _init() -> void:
    name = &"myplugin_widget_label"
    display_name = "Widget Label"
    schema_version = 1
    owning_plugin = &"myplugin"
    primitives_optional = true
    default_payload = {"text": ""}


func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
    var payload: Dictionary = annotation.get("kind_payload", {})
    var pos: Variant = ctx.host.resolve_position_source(annotation.get("anchor", null))
    if pos == null:
        return
    ctx.draw_string(null, pos as Vector2, str(payload.get("text", "")), Color.WHITE, 12)


func bounds(annotation: Dictionary) -> Rect2:
    var pos: Variant = AnnotationKind._to_vec2(annotation.get("anchor", {}).get("snapshot", {}).get("position", []))
    return Rect2(pos as Vector2, Vector2(80.0, 16.0))


func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
    return bounds(annotation).grow(threshold).has_point(point)
```

### 2.2 Identity fields

| Field | Type | Notes |
|---|---|---|
| `name` | `StringName` | Globally unique, matches the `kind` discriminator in JSON |
| `display_name` | `String` | Human-readable label for toolbar / list rows |
| `schema_version` | `int` | Bump on breaking payload changes; triggers `migrate()` |
| `owning_plugin` | `StringName` | `&"core"` for built-ins; the plugin id otherwise |
| `primitives_optional` | `bool` | Set true when geometry lives in `kind_payload` or `anchor` |

### 2.3 Required virtuals

`render(ctx, annotation)`, `bounds(annotation)`, and `hit_test(annotation, point, threshold)` are the contract. The base `hit_test` falls back to a grown AABB of `bounds()` when not overridden.

### 2.4 Optional virtuals

| Method | Purpose |
|---|---|
| `validate(annotation) -> Array` | Kind-specific extra validation (returns array of error dicts) |
| `accepted_anchor_types() -> Array` | Pattern list (`"plugin/*"` etc.) used by schema compat checks |
| `migrate(annotation, from_version) -> Dictionary` | Schema upgrade hook |
| `rewrite_paths(annotation, mode, base) -> Dictionary` | Project pack/unpack path rewrite |
| `summary(annotation) -> String` | One-line LLM-readable description |
| `body_view_factory(annotation, emit_patch) -> Control` | Workbench detail pane (see [§5](#5-body-views-t5)) |
| `actions(annotation) -> Array` | Per-row action buttons (see [§6](#6-per-kind-actions-t_apply-phase-a)) |
| `run_action(action_id, annotation, phase, host) -> Dictionary` | Action handler |
| `author_ui() -> Object` | Authoring tool factory (see [§7](#7-custom-authoring-tools)) |
| `has_visual_render() -> bool` | Opt out of platform rendering (see [§8](#8-host-owned-canvas-opt-out)) |
| `transform_annotation(annotation, transform, op) -> Dictionary` | Custom geometry transforms |
| `to_chat_context(annotation, capabilities) -> Array` | Chat block synthesis |

### 2.5 Registration

The registry is owned by the host. Built-in kinds register through `BuiltinKinds.register_all(registry)`; plugins register their own immediately after:

```gdscript
class_name Myplugin_AnnotationHost
extends AnnotationHost

const _MyKindScript = preload("res://plugins/myplugin/ui/kinds/myplugin_widget_label_kind.gd")

var _registry: AnnotationRegistry = null


func _init() -> void:
    super._init()
    _registry = AnnotationRegistry.new()
    BuiltinKinds.register_all(_registry)
    _registry.register_annotation_kind(_MyKindScript.new())


func get_registry() -> AnnotationRegistry:
    return _registry
```

`register_annotation_kind` returns `false` on collision, on null, on empty `name`, or on a `2d_*` namespace violation. It does not throw — check the return value if a duplicate registration could be a real bug.

### 2.6 Capabilities

Hosts override `get_capabilities()` to advertise what their workbench should expose. The shape is documented on `AnnotationHost.default_capabilities()`. Add your custom kind name to the `kinds` array so the workbench filters it correctly:

```gdscript
func get_capabilities() -> Dictionary:
    return {
        "kinds": ["myplugin_widget_label", "callout", "2d_arrow"],
        "tools": ["select"],
        "anchor_types": ["myplugin/widget.point", "core/canvas.point"],
        "lifecycle": {
            "resolve": true, "reopen": true, "delete": true,
            "repair": false, "apply": true,
        },
        "authoring": {"add": true, "domain_pickers": false},
        "panes": false,
        "body_views": true,
        "filters": ["all", "open", "applied", "resolved", "broken"],
    }
```

`AnnotationHost.normalize_capabilities` merges your dict over the defaults, so missing sub-keys inherit safe falses.

---

## 3. Custom Anchor Types

An anchor envelope is `{plugin: String, type: String, id: Variant, snapshot: {position: ...}}` plus optional fields. The substrate validates only the common shape; the plugin owns everything else via a resolver.

### 3.1 Resolver registration

`AnnotationHost.register_anchor_resolver(anchor_type, resolver)` keys a callable on the full `"<plugin>/<type>"` string. Call it from your host's `_init` (after `super._init()`):

```gdscript
func _init() -> void:
    super._init()
    register_anchor_resolver("myplugin/widget.point", Callable(self, "_resolve_widget_point"))


func _resolve_widget_point(anchor: Dictionary) -> Dictionary:
    var snapshot: Dictionary = anchor.get("snapshot", {})
    var pos := AnnotationKind._to_vec2(snapshot.get("position", []))
    var widget := _lookup_widget(str(anchor.get("id", "")))
    if widget == null:
        return {"position": pos, "stale": true, "view_metadata": {}}
    return {
        "position": widget.global_position + pos,
        "bounds": widget.get_global_rect(),
        "stale": false,
        "view_metadata": {"label": str(anchor.get("id", ""))},
    }
```

A resolver returns a Dictionary `{position, bounds, stale, view_metadata}`. Missing fields are filled in from the snapshot by `AnnotationHost._normalise_resolve_result`. Returning a non-Dictionary marks the anchor stale at the snapshot position.

### 3.2 Substrate-owned fast path: `core/canvas.point`

The base class resolves `core/canvas.point` without a registered callable. Anchors of the form `{plugin: "core", type: "canvas.point", id: {x, y}, snapshot: {position: [x, y]}}` are returned directly with `stale: false`. Plugins that want a free-canvas endpoint should reuse this anchor type rather than minting a new one.

### 3.3 Position source resolution

Kinds that take an endpoint-like value should call `host.resolve_position_source(source)` rather than dispatching by type:

```gdscript
func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
    var payload: Dictionary = annotation.get("kind_payload", {})
    var a: Variant = ctx.host.resolve_position_source(payload.get("endpoint_a", null))
    var b: Variant = ctx.host.resolve_position_source(payload.get("endpoint_b", null))
    if a is Vector2 and b is Vector2:
        ctx.draw_line(a as Vector2, b as Vector2, Color.WHITE, 1.5)
```

The function accepts `Vector2`, `Vector3`, `[x, y]`, `{x, y}`, and full anchor dicts. It returns `null` when nothing is resolvable so callers can early-out without rendering broken geometry.

### 3.4 Optional `AnnotationAnchorRegistry` integration

A separate `AnnotationAnchorRegistry` exists for anchor-type-level metadata: `validate(anchor)`, `summary(anchor, host)`, and `repair(anchor, host)`. Hosts opt in by overriding `get_anchor_registry()` and registering an `AnchorResolver` subclass:

```gdscript
class WidgetPointResolver extends AnnotationAnchorRegistry.AnchorResolver:
    func validate(anchor: Dictionary) -> Array:
        var errors: Array = []
        if not anchor.has("id"):
            errors.append("id required")
        return errors

    func summary(anchor: Dictionary, _host: Object) -> String:
        return "widget:%s" % str(anchor.get("id", ""))


func _init() -> void:
    super._init()
    _anchor_registry = AnnotationAnchorRegistry.new()
    _anchor_registry.register("myplugin", "widget.point", WidgetPointResolver.new())


func get_anchor_registry() -> Object:
    return _anchor_registry
```

`AnnotationHost.validate_annotation_anchor(annotation)` walks the registry when one is present; hosts call it before storing.

---

## 4. Custom Kind Payloads

Annotations carry two opaque slots:

- `anchor` — validated for shape by `AnnotationV2Schema._validate_anchor`. The substrate cares only about `plugin`, `type`, `id`, and `snapshot.position`.
- `kind_payload` — entirely opaque. Only the kind that owns the annotation reads it.

The substrate guarantees round-trip through `AnnotationV2Schema.serialize` / `deserialize`. The only computed field stripped on serialize is `anchored_to`, which is re-derived from `anchor.plugin/type/id` on deserialize.

### 4.1 Validation gotcha

`AnnotationV2Schema.validate` is registry-blind: it uses the hard-coded `_GENERIC_KIND_ANCHORS` table to check kind/anchor compatibility. That table covers core kinds only. If your kind is not in it, raw `validate(envelope)` will report `kind_anchor_incompatible` even when your `accepted_anchor_types()` would allow the pairing.

Use `validate_with_registry(envelope, registry)` instead. It re-runs the compatibility check through `kind.accepted_anchor_types()` so plugin kinds get the same treatment as built-ins:

```gdscript
func add_annotation_v2(envelope: Dictionary) -> String:
    var schema := AnnotationV2Schema.new()
    var result := schema.validate_with_registry(envelope, _registry)
    if result.has_errors():
        push_warning("validation errors: %s" % str(result.to_error_dicts()))
        return ""
    _annotations.append(envelope)
    annotations_changed.emit()
    return str(envelope.get("id", ""))
```

`TextEditorAnnotationHost.add_annotation_v2` is the canonical example.

### 4.2 `accepted_anchor_types`

Override on your kind to whitelist anchor types it accepts. Patterns support `"core/*"`, `"myplugin/widget.point"`, and `"*/*"` (any). Built-in `callout` uses `"*/*"`; the built-in 2d_* kinds use `"core/*"`.

```gdscript
func accepted_anchor_types() -> Array:
    return ["myplugin/widget.point", "core/canvas.point"]
```

### 4.3 `view_context` is immutable

`AnnotationV2Schema.check_view_context_immutable` is called on update. Once an annotation is created with `view_context: "cad:top"` you cannot move it to `view_context: "cad:front"` via `update_annotation`. Author a new annotation instead.

---

## 5. Body Views (T5)

When an annotation is selected, the workbench can render a per-kind detail Control beneath the list. The kind opts in by overriding `body_view_factory`.

### 5.1 Signature

```gdscript
func body_view_factory(annotation: Dictionary, emit_patch: Callable) -> Control
```

`AnnotationWorkbench._refresh_body_view` calls this with the live annotation and a closure that shallow-merges a patch dict back into the host:

```gdscript
var emit := func(patch: Dictionary) -> void:
    if _host != null and _host.has_method("update_annotation"):
        var merged: Dictionary = annotation.duplicate(true)
        merged.merge(patch, true)
        _host.update_annotation(annotation_id, merged)
```

The workbench frees the previous view (`_current_body_view.queue_free()`) on selection change and host swap.

### 5.2 Worked example: `AnnotationTextComment.body_view_factory`

```gdscript
func body_view_factory(annotation: Dictionary, _emit_patch: Callable) -> Control:
    var payload: Dictionary = annotation.get("kind_payload", {})
    var comment_text := str(payload.get("text", ""))

    var vbox := VBoxContainer.new()

    var body := Label.new()
    body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    body.text = comment_text
    vbox.add_child(body)

    var footer := HBoxContainer.new()
    var author_kind := str(annotation.get("author", {}).get("kind", ""))
    var author_label := Label.new()
    author_label.text = author_kind if not author_kind.is_empty() else "unknown"
    footer.add_child(author_label)

    var lifecycle_label := Label.new()
    lifecycle_label.text = str(annotation.get("lifecycle", "open"))
    footer.add_child(lifecycle_label)
    vbox.add_child(footer)

    return vbox
```

### 5.3 Mounting

The workbench owns a `_body_view_container: PanelContainer`; you don't add yourself there. You return a Control and the workbench parents it. Returning `null` (or anything non-Control) hides the container.

### 5.4 Capability flag

Set `capabilities.body_views = true` so the workbench's host-capability checks treat body views as supported. The container is shown only when `body_view_factory` returns a non-null Control, but the capability flag lets the workbench reserve layout space without a flicker on first selection.

---

## 6. Per-Kind Actions (T_apply Phase A)

Kinds advertise per-row buttons via `actions`. The workbench surfaces them next to the lifecycle buttons (Apply / Resolve / Del / etc.) on each row.

### 6.1 Signatures

```gdscript
func actions(annotation: Dictionary) -> Array:
    return [
        {"id": "open_in_editor", "label": "Open"},
        {"id": "fix_typo", "label": "Auto-fix", "requires_lifecycle": ["open"]},
    ]


func run_action(action_id: String, annotation: Dictionary, phase: String, host: AnnotationHost) -> Dictionary:
    match action_id:
        "open_in_editor":
            if phase == "dry_run":
                return {"ok": true}
            host.update_annotation_lifecycle(str(annotation.get("id", "")), "applied", {})
            return {"ok": true, "lifecycle": "applied"}
        "fix_typo":
            ...
    return {"ok": false, "error": "unknown action"}
```

Action entries are dicts. Required keys: `id`, `label`. Optional: `requires_lifecycle: Array[String]`. The workbench filters out actions whose `requires_lifecycle` doesn't contain the annotation's current lifecycle.

### 6.2 Two-phase apply

`AnnotationWorkbench._run_action` routes through `AnnotationApplyToolRunner.apply(tool_id, annotation_id, hook, host)`. The runner calls the hook twice:

1. `phase: "dry_run"` — return `{ok: true}` if the action is currently valid, `{ok: false, error}` otherwise. Failures short-circuit before commit.
2. `phase: "commit"` — perform the side effect. Return `{ok: true, lifecycle?: String, ...}`. If `lifecycle` is set the workbench then calls `host.update_annotation_lifecycle(id, lifecycle, {})`.

Between phases the runner snapshots host state via `host.capture_state_snapshot()` if available. Commit failures trigger `host.restore_state_snapshot(snapshot)` so partially-applied side effects roll back.

### 6.3 Failure handling

`AnnotationApplyToolRunner._call_hook` records failures with `trust_manager.record_apply_tool_throw(tool_id, phase, error)`. Hard exceptions thrown from `run_action` propagate out of the closure; the workbench surfaces the message via `show_status`. Return `{ok: false, error: "..."}` rather than throwing — that path is recorded as a soft failure and counts toward suspension thresholds without crashing the editor. See [§9](#9-trust-boundary).

### 6.4 Capability

Set `capabilities.lifecycle.apply = true` to expose the substrate's "Applied" button. Per-kind actions are surfaced regardless of that flag — they don't need a capability switch.

---

## 7. Custom Authoring Tools

A kind may return an `AnnotationAuthorTool` instance from `author_ui()`. The toolbar surfaces a button per such kind; activating it forwards pointer events to the tool until it commits or cancels.

### 7.1 The base contract

Subclasses override:

- `on_activate(host: AnnotationHost) -> void`
- `on_deactivate() -> void`
- `on_pointer_down(pos: Vector2, button: int, mods: int) -> bool` — return true to consume
- `on_pointer_move(pos: Vector2) -> void`
- `on_pointer_up(pos: Vector2, button: int, mods: int) -> bool` — return true to consume
- `draw_preview(ctx: AnnotationRenderContext) -> void`

And emit one of:

- `annotation_ready(annotation: Dictionary)` — for tools that **create** new annotations
- `annotation_modified(annotation_id: String, new_annotation: Dictionary)` — for tools that **modify** existing ones
- `cancelled()` — on Escape, right-click, or post-commit teardown

A given subclass should pick exactly one committal signal. `cancelled()` is shared.

### 7.2 Worked example: `cad_edge_number_tool.gd`

The CAD edge-number tool is a one-shot click-to-place authoring tool. The shape:

```gdscript
extends "res://Scripts/Services/Annotations/AnnotationAuthorTool.gd"

enum _State { IDLE, DONE }

var _state: int = _State.IDLE
var _host: Object = null


func on_activate(host: AnnotationHost) -> void:
    _host = host
    _state = _State.IDLE


func on_deactivate() -> void:
    _host = null
    _state = _State.IDLE


func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
    if mods == KEY_ESCAPE or button == MOUSE_BUTTON_RIGHT:
        on_deactivate()
        cancelled.emit()
        return true
    if button != MOUSE_BUTTON_LEFT or _state != _State.IDLE or _host == null:
        return false
    var result := resolve_click(pos, _host)
    if result.is_empty():
        return true  # consume but don't commit
    _state = _State.DONE
    annotation_ready.emit(_build_annotation(result))
    on_deactivate()
    cancelled.emit()
    return true
```

The tool calls `resolve_click(pos, host)` (a static helper in this case) to compute the picked edge, then builds a fully-formed v2 envelope and emits `annotation_ready`. The toolbar's `_on_annotation_ready` handler is what calls `host.add_annotation` — tools must not call it directly. This keeps the toolbar UI in sync with authoring state.

### 7.3 Filtering

Toolbar enumerates `host.get_capabilities().kinds`, filters to those whose `author_ui()` returns non-null, and creates one button per kind. Returning `null` from `author_ui()` opts the kind out of toolbar surfacing while still allowing programmatic / MCP-driven creation.

---

## 8. Host-Owned Canvas Opt-Out

Some kinds are best drawn by the host's own renderer instead of the platform overlay. Examples: a code-editor underline that must align with glyph positions, or a PCB highlight that must integrate with the trace renderer's z-order.

### 8.1 The flag

```gdscript
func has_visual_render() -> bool:
    return false
```

When this returns false:

- `AnnotationOverlay._draw` skips `registry.dispatch_render(ctx, ann)` for the annotation.
- The number badge is skipped.
- The selection halo is skipped.
- The kind's own `bounds()` is never called by the overlay.

The host is then responsible for everything visual — underline, highlight, badge, halo — and must observe `host.annotations_changed` and `host.selection_changed` itself.

### 8.2 Overlay guard

The relevant guard lines in `AnnotationOverlay._draw`:

```gdscript
for ann in _host.get_annotations():
    if registry != null:
        var ann_kind_name := StringName((ann as Dictionary).get("kind", "")) if ann is Dictionary else StringName("")
        var ann_kind: AnnotationKind = registry.get_annotation_kind(ann_kind_name)
        if ann_kind != null and not ann_kind.has_visual_render():
            continue
        registry.dispatch_render(ctx, ann)
    if ann is Dictionary:
        _draw_annotation_number_badge(ann as Dictionary)
```

And the selection halo:

```gdscript
if not kind.has_visual_render():
    break
```

Both early-out the moment the kind opts out.

### 8.3 Worked example: `AnnotationTextComment` + `TextEditorAnnotationHost`

`AnnotationTextComment.has_visual_render()` returns false. Its `bounds()` is implemented as `Rect2()` — a deliberate empty rect — because the abstract contract requires the override but the platform overlay never calls it. The visual signal lives entirely on the text editor side: gutter badges, underlines, and the live-text canvas inside `TextEditorAnnotationHost`'s consumers. The annotation envelope itself carries only the anchor (a `core/text.range`) and the comment payload.

### 8.4 When to opt out vs. when to render normally

| Opt out (`has_visual_render() == false`) | Use platform render |
|---|---|
| Visual must align pixel-perfect with host content (glyphs, traces, PCB layers) | Visual is independent of host content (callouts, free-space arrows) |
| Host already has a renderer for this artifact | Substrate's `AnnotationRenderContext` is sufficient |
| Z-order must interleave with host | Z-order can sit above the host content |

If unsure, opt **in** to platform render. The overlay is the simpler path and gets you badges/halos/lifecycle visuals for free.

---

## 9. Trust Boundary

`AnnotationTrustManager` watches plugin contributions. When a kind, resolver, or apply tool fails too often within a short window, the manager suspends it. Suspended contributions stay quiet until explicitly resumed.

### 9.1 Failure surfaces

| Surface | Recorder method | Suspension check |
|---|---|---|
| Render | `record_render_throw(kind, error)` | `is_kind_suspended(kind)` |
| Anchor resolver | `record_resolver_throw(plugin, anchor_type, error)` | `is_anchor_type_suspended(plugin, anchor_type)` |
| Apply tool | `record_apply_tool_throw(tool_id, phase, error)` | `is_apply_tool_suspended(tool_id)` |

Defaults (tunable in source):

- Render threshold: 5 throws per 60 s
- Resolver threshold: 5 per 60 s
- Apply-tool threshold: 3 per 60 s

When the threshold trips, `_suspend` records the suspension dict (`type`, `name`, `throw_count`, `suspended_at`, `error_samples`) on the manager.

### 9.2 Soft vs. hard failure

`AnnotationApplyToolRunner._call_hook`:

```gdscript
func _call_hook(tool_id: String, hook: Callable, annotation_id: String, phase: String) -> Dictionary:
    var result: Variant = hook.call(annotation_id, phase)
    if result is Dictionary:
        var dict: Dictionary = result
        if not dict.has("ok"):
            dict["ok"] = true
        if not dict.get("ok", false) and trust_manager != null:
            trust_manager.record_apply_tool_throw(tool_id, phase, str(dict.get("error", "apply tool failed")))
        return dict
    return {"ok": false, "error": "apply hook returned non-dictionary"}
```

The pattern: **return a soft failure dict from `run_action` rather than throwing**. A soft failure (`{ok: false, error}`) increments the trust counter. A thrown exception bypasses the runner entirely and propagates; depending on the call site this can hard-suspend or surface as an editor-level error.

### 9.3 Recovery

`resume_kind(name)`, `resume_anchor_type(plugin, anchor_type)`, and `resume_apply_tool(tool_id)` lift the suspension. There is no automatic timer — recovery is explicit. UI is expected to call resume when the user dismisses the suspension state.

`get_suspensions()` and `get_throw_history(window_sec)` give the workbench the data it needs to surface the trust state.

---

## 10. Off-Tree Plugin Gotchas

Plugins live outside `res://`. Several Godot conventions break or behave subtly differently in that location.

### 10.1 No `class_name` for off-tree scripts

Godot's parser only indexes `class_name` declarations under `res://`. An off-tree script that declares `class_name Foo` is parsed but the name is invisible: `Foo` typed parameters fail to resolve from another off-tree script.

The workaround is mechanical:

```gdscript
# Off-tree plugin file
# DO NOT write: class_name MyKind

extends "res://Scripts/Services/Annotations/AnnotationAuthorTool.gd"

const _MyOtherScript = preload("../tools/cad_edge_number_tool.gd")
```

Reference the base class via `extends "<res://-or-relative-path>"`. Reference sibling scripts via `preload(...)`. Reference platform classes (which DO have `class_name`) directly — `AnnotationKind`, `AnnotationHost`, `AnnotationRenderContext` all resolve from off-tree.

In-tree plugins (under `src/plugins/`) can keep `class_name` because they live in `res://`. Off-tree plugins should declare `class_name` only for documentation; do not rely on cross-script visibility for it. The CAD reference implementation declares `class_name Cad_AnnotationHost` in its host file, but other scripts in the same plugin still reach the host through `preload("res://path/to/CadAnnotationHost.gd")` and base-class typing on `AnnotationHost`, not by naming `Cad_AnnotationHost` directly.

### 10.2 Manifest scripts whitelist

Every plugin script that can be `preload`ed at runtime must be declared in **both**:

- The on-disk manifest at `<plugin>/manifest.json` under `ui.panels[].scripts`
- The cached registry at `~/.local/share/godot/app_userdata/Minerva/plugins/plugins.json` under the same path

An undeclared script is rejected by the platform's plugin loader at preload time. Adding a new kind file or tool file means editing both. The disk manifest is the source of truth; the cached registry is rewritten on plugin install / reload — but a stale cache after a manual edit will silently drop new scripts. Run `Reload Plugins` (or restart) after touching scripts arrays.

This is recorded as nudge `minerva-plugin-platform/manifest_script_whitelist`.

### 10.3 Closure write-back through Array wrapper

GDScript closures capture primitives by value but Arrays/Dicts by reference. When an apply hook needs to write its commit-phase result back to the enclosing scope, wrap the receiver in a single-element Array:

```gdscript
var commit_result: Array = [{}]
var hook := func(ann_id: String, phase: String) -> Dictionary:
    var ann: Dictionary = _lookup(ann_id)
    var hook_result: Dictionary = kind.run_action(action_id, ann, phase, _host as AnnotationHost)
    if phase == "commit":
        commit_result[0] = hook_result
    return hook_result

var apply_result: Dictionary = _ensure_apply_runner().apply(action_id, annotation_id, hook, _host)
var next_lifecycle := str((commit_result[0] as Dictionary).get("lifecycle", ""))
```

`AnnotationWorkbench._run_action` uses exactly this pattern because `ApplyToolRunner.apply()` returns only `{ok, error?}` — the kind-supplied lifecycle hint lives in the hook's return value, not the runner's.

---

## 11. PCB Adoption Sketch

The PCB editor migration is tracked in [`Docs/PCB-annotation-migration.md`](../PCB-annotation-migration.md). That doc is the source of truth; this section gives an overview only.

The plan in shape:

- One `Pcb_AnnotationHost` mounted by the PCB editor.
- Custom anchor types keyed by net id, pad reference, and component refdes (e.g. `pcb/net.id`, `pcb/pad`, `pcb/component.refdes`).
- Resolvers translate those references to current document-space positions, returning `stale: true` when the referenced entity is missing or moved.
- Highlight kinds (e.g. trace highlight, pad ring) are likely to set `has_visual_render() == false` so the PCB renderer integrates them with its layer order.
- Free-space callouts continue to use the built-in `callout` kind with `core/canvas.point` endpoints.

The migration doc is the authority for the staging plan, capability list, and which existing PCB annotation features map to which substrate primitives.

---

## 12. CAD Adoption Sketch

This section sketches the pattern for adopting the substrate in a multi-viewport CAD-style host. All of the patterns below are inlined; the CAD plugin you can build alongside them does not need to live in the Minerva tree (the reference implementation is off-tree and does not need to be read to follow this section).

The CAD-style adoption has three pieces:

- **A host** that advertises multiple viewports (panes) and a camera per pane.
- **A kind** that uses 3D anchors and projects through each pane's camera in `render`.
- **An authoring tool** that picks a 3D point or geometry feature and stamps an annotation.

A reference implementation of all three lives off-tree at `~/github/plugins/cad/ui/` — `CadAnnotationHost.gd`, `kinds/cad_edge_number_kind.gd`, and `tools/cad_edge_number_tool.gd`. Patterns from those files are reproduced below; you do not need access to them to write your own CAD-style plugin.

### 12.1 Multi-pane implications

The CAD panel runs four viewports (Top, Front, Right, Iso). The host advertises them via `get_panes()`:

```gdscript
func get_panes() -> Array:
    var result: Array = []
    var seen_viewports := {}
    for pane_id in WIDE_PANE_IDS:
        var cam: Variant = _camera_for.get(pane_id, null)
        var vp: Variant = _viewport_for.get(pane_id, null)
        if cam == null or vp == null:
            continue
        var vp_id: int = vp.get_instance_id() if vp.has_method("get_instance_id") else 0
        if vp_id != 0 and seen_viewports.has(vp_id):
            continue
        seen_viewports[vp_id] = true
        result.append({
            "name": pane_id,
            "camera": cam,
            "viewport_rect": _compute_viewport_rect(pane_id),
        })
    return result
```

A kind that wants to draw in every pane uses 3D anchors (encoded as 3-element `at` arrays in primitives) and projects through each pane's camera in `render`:

```gdscript
for pane in panes:
    var camera: Variant = (pane as Dictionary).get("camera", null)
    if camera == null or not camera.has_method("unproject_position"):
        continue
    var screen_pos: Vector2 = camera.unproject_position(world_pos)
    var rect: Rect2 = (pane as Dictionary).get("viewport_rect", Rect2())
    screen_pos += rect.position
    _draw_callout(ctx, screen_pos, label_text, leader_color)
```

### 12.2 2D ortho panes are x-ray outlines

The Top / Front / Right panes are not 3D rendered scenes — they are 2D x-ray outlines of the CAD geometry. This is a project-level constraint that affects what `render_content_to_image` can return for those panes and what visual style annotations should use to read against the outline (high contrast, no fill, leader lines anchored to projected edge midpoints rather than face centroids).

### 12.3 What the CAD scaffold defers

The current Cad_AnnotationHost stubs identity transforms, returns `""` from `describe_point`, and does not yet implement BVH/edge proximity queries. The full CAD migration — semantic hit-testing, plane resolvers, mesh-face anchors, edge anchors with stable IDs across re-evaluation — is its own work item.

---

## 13. In-Tree Reference Implementations

> This appendix is for Minerva maintainers. Plugin authors do not need to read these files — every signature and pattern they expose is already inlined in the sections above.

Substrate base classes:

- `src/Scripts/Services/Annotations/AnnotationHost.gd`
- `src/Scripts/Services/Annotations/AnnotationKind.gd`
- `src/Scripts/Services/Annotations/AnnotationOverlay.gd`
- `src/Scripts/Services/Annotations/AnnotationAuthorTool.gd`
- `src/Scripts/Services/Annotations/AnnotationApplyToolRunner.gd`
- `src/Scripts/Services/Annotations/AnnotationTrustManager.gd`
- `src/Scripts/Services/Annotations/AnnotationAnchorRegistry.gd`
- `src/Scripts/Services/Annotations/AnnotationRegistry.gd`
- `src/Scripts/Services/Annotations/AnnotationV2Schema.gd`
- `src/Scripts/Services/Annotations/BuiltinKinds.gd`
- `src/Scripts/UI/Controls/AnnotationDockPane/AnnotationWorkbench.gd`

Worked examples:

- `src/Scripts/Services/Annotations/kinds/AnnotationTextComment.gd` — host-owned canvas opt-out with body view.
- `src/Scripts/Services/Annotations/TextEditorAnnotationHost.gd` — first text-editor host adoption; canonical `validate_with_registry` usage.
- `src/plugins/hello_scene/ui/HelloAnnotationHost.gd` — first plugin host adoption.
- `~/github/plugins/cad/ui/CadAnnotationHost.gd` — second plugin host (off-tree).
- `~/github/plugins/cad/ui/kinds/cad_edge_number_kind.gd` — custom kind with multi-pane render.
- `~/github/plugins/cad/ui/tools/cad_edge_number_tool.gd` — custom authoring tool with click-to-place.

Sibling design docs:

- [`Annotation-substrate-design.md`](./Annotation-substrate-design.md) — substrate architecture and contract.
- [`../PCB-annotation-migration.md`](../PCB-annotation-migration.md) — PCB editor migration plan.

---

## 14. Out of Scope

Two follow-on migrations are not part of this guide:

- **Full PCB migration.** Tracked in `Docs/PCB-annotation-migration.md`. New T-tasks file when scheduled.
- **Full CAD migration.** Semantic hit-testing, BVH-backed edge queries, real camera transforms, mesh-face anchors, and the rest of the multi-pane work are deferred. The CAD scaffold at `~/github/plugins/cad/ui/` is enough to validate the contract; it is not the finished editor.

This document is the contract plugin authors implement. The migrations are separate work items that consume that contract.
