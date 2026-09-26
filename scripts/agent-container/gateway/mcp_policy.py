"""What an agent container may ask of the host MCP services, and how.

Pure policy, no sockets: mcp_http.py calls parse_request() on every JSON-RPC
body, plan_call() on every tools/call, and shape_*() on every upstream answer.
Everything not allowed by policy.json is denied before it reaches an
upstream, and nothing an upstream sends is relayed as-is: each answer is
rebuilt from values the gateway has checked, so upstream error details,
structuredContent and extra fields never reach the container.

Deny and ProtocolError carry a fixed code (safe to log) and a detail (shown
only to the container, bounded, never upstream data).
"""
from dataclasses import dataclass
import json
import re

import docket_scope
import strict_json

MAX_RESULT_TEXT = 4 * 1024 * 1024
LINE_MAX = 512
TEXT_MAX = 64 * 1024
JSON_ARG_MAX = 64 * 1024
LIST_MAX = 64
DETAIL_MAX = 200
ERROR_TEXT_MAX = 500
NOTIFY_TEXT_MAX = 400      # Minerva's NOTIFY_MAX_TEXT_LENGTH
NOTIFY_WAIT_MAX = 20000    # Minerva's NOTIFY_MAX_WAIT_MS
QUERY_LIMIT_MAX = 200
# Attachment data travels inside one request body (mcp_http.MAX_REQUEST_BODY).
BASE64_MAX = 900 * 1024
ID_MAX = 2**53

METHODS = {"initialize", "notifications/initialized", "ping", "tools/list", "tools/call"}
ENVELOPE_KEYS = {"jsonrpc", "id", "method", "params"}
PARAM_KEYS = {
    "initialize": {"protocolVersion", "capabilities", "clientInfo", "_meta"},
    "notifications/initialized": {"_meta"},
    "ping": {"_meta"},
    "tools/list": {"cursor", "_meta"},
    "tools/call": {"name", "arguments", "_meta"},
}
REF = re.compile(r"(?:([A-Za-z0-9._-]{1,64}):)?([0-9a-f]{32})")
NOTE_ID = re.compile(r"[0-9a-f]{32,64}")
TOOL_NAME = re.compile(r"[a-z0-9_]{1,64}")
PROTOCOL_VERSION = re.compile(r"[0-9A-Za-z.-]{1,32}")
# Characters that end or fake a line in a terminal or a Docket field.
LINE_BREAKERS = re.compile("[\x00-\x1f\x7f\x85\u2028\u2029]")
TEXT_FORBIDDEN = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
BASE64 = re.compile(r"[A-Za-z0-9+/]*={0,2}")
KIND_SCHEMA = {
    "line": {"type": "string", "maxLength": LINE_MAX},
    "project": {"type": "string"},
    "text": {"type": "string", "maxLength": TEXT_MAX},
    "int": {"type": "integer"},
    "bool": {"type": "boolean"},
    "str_list": {"type": "array", "items": {"type": "string"}, "maxItems": LIST_MAX},
    "json": {},
    "ref": {"type": "string", "pattern": REF.pattern},
    "note_id": {"type": "string", "pattern": NOTE_ID.pattern},
    "base64": {"type": "string", "maxLength": BASE64_MAX},
}


def _bounded(text):
    return text if len(text) <= DETAIL_MAX else text[:DETAIL_MAX] + "…"


class Deny(Exception):
    """A request or answer the policy refuses."""

    def __init__(self, code, detail=""):
        self.code, self.detail = code, _bounded(detail)
        super().__init__(f"{code}: {self.detail}" if self.detail else code)


class ProtocolError(Exception):
    """A malformed JSON-RPC message."""

    def __init__(self, rpc_code, code, detail=""):
        self.rpc_code, self.code, self.detail = rpc_code, code, _bounded(detail)
        super().__init__(f"{code}: {self.detail}" if self.detail else code)


@dataclass(frozen=True)
class Binding:
    """Which Minerva terminal is attached to a session right now. Terminal ids
    change when Minerva restarts, so this comes from the launcher's binding
    file on every call, never from startup. It is the reply address the
    gateway stamps on a notify, and the one terminal a notify may not name."""
    terminal_id: object     # str, or None when no terminal is attached


UNATTACHED = Binding(None)


@dataclass(frozen=True)
class Grants:
    """What Minerva currently lets this session do beyond the fixed policy:
    the notes it may read and write (write implies read), whether it may
    notify other harness tabs at all, and the session identity and role
    Minerva registered for it, which decide its Docket scope (docket_scope.py;
    "" = none registered, so nothing in Docket is in scope). Minerva rewrites
    the grant record while the session runs; the gateway reads it on every
    call, so a change applies to the next call and nothing is fixed at start
    or attach."""
    read: frozenset
    write: frozenset
    notify: bool
    identity: str = ""
    role: str = ""


NO_GRANTS = Grants(frozenset(), frozenset(), False)


@dataclass(frozen=True)
class Session:
    """One long-running agent session, as registered by the trusted launcher.
    binding() returns the current Binding, grants() the current Grants."""
    name: str
    harness: str
    docket_projects: frozenset
    binding: object
    grants: object = lambda: NO_GRANTS

    @property
    def label(self):
        # Stable across reattaches; cannot collide with a Minerva tab name.
        return f"container:{self.harness}@{self.name}"


@dataclass(frozen=True)
class Request:
    id: object          # None for a notification
    method: str
    params: dict

    @property
    def is_notification(self):
        return self.id is None


@dataclass
class Call:
    """A tools/call the policy lets through: what to forward, and how to
    rebuild the upstream's result for the container."""
    arguments: dict
    shape: object

    def shape_result(self, result):
        return self.shape(result)


class Policy:
    def __init__(self, data):
        self.readable_types = frozenset(data["docket_readable_types"])
        self.mutable_types = frozenset(data["docket_mutable_types"])
        if not self.mutable_types <= self.readable_types:
            raise ValueError("every mutable Docket type must also be readable")
        self.services = data["services"]
        for service, tools in self.services.items():
            for name, spec in tools.items():
                if set(spec) - {"args", "required", "rule"}:
                    raise ValueError(f"{service}.{name}: unknown spec keys")
                for arg in spec["required"]:
                    if arg not in spec["args"]:
                        raise ValueError(f"{service}.{name}: required {arg} not in args")
                for kind in spec["args"].values():
                    if not (isinstance(kind, dict) and set(kind) == {"enum"}) and kind not in KIND_SCHEMA:
                        raise ValueError(f"{service}.{name}: unknown argument kind {kind}")
                rule = spec.get("rule")
                if rule is not None and rule not in RULES:
                    raise ValueError(f"{service}.{name}: unknown rule {rule}")

    @classmethod
    def load(cls, path):
        with open(path, "rb") as f:
            return cls(strict_json.loads(f.read(), 1024 * 1024))

    def tools(self, service):
        return self.services.get(service, {})


# ── JSON-RPC envelope ──────────────────────────────────────────────────────

def request_id(msg):
    """The id to answer a message with, when it has a well-formed one."""
    if isinstance(msg, dict):
        rid = msg.get("id")
        if (isinstance(rid, int) and not isinstance(rid, bool) and abs(rid) <= ID_MAX) \
                or (isinstance(rid, str) and 0 < len(rid) <= 128):
            return rid
    return None


def _check_initialize(params):
    if not isinstance(params.get("protocolVersion"), str) \
            or not PROTOCOL_VERSION.fullmatch(params["protocolVersion"]):
        raise ProtocolError(-32602, "bad_initialize", "protocolVersion")
    for key, limit in (("capabilities", 16384), ("clientInfo", 4096)):
        if not isinstance(params.get(key, {}), dict) or len(strict_json.dumps(params.get(key, {}))) > limit:
            raise ProtocolError(-32602, "bad_initialize", key)


def parse_request(msg):
    """Validate one JSON-RPC 2.0 request or notification; batches are refused."""
    if isinstance(msg, list):
        raise ProtocolError(-32600, "batch_refused")
    if not isinstance(msg, dict):
        raise ProtocolError(-32600, "not_an_object")
    extra = set(msg) - ENVELOPE_KEYS
    if extra:
        raise ProtocolError(-32600, "unknown_envelope_field", ", ".join(sorted(extra)))
    if msg.get("jsonrpc") != "2.0":
        raise ProtocolError(-32600, "bad_jsonrpc_version")
    method = msg.get("method")
    if not isinstance(method, str):
        raise ProtocolError(-32600, "bad_method")
    if "id" in msg and request_id(msg) is None:
        raise ProtocolError(-32600, "bad_id")
    params = msg.get("params", {})
    if not isinstance(params, dict):
        raise ProtocolError(-32602, "bad_params")
    if method not in METHODS:
        raise ProtocolError(-32601, "method_not_available", method)
    if method.startswith("notifications/") != ("id" not in msg):
        raise ProtocolError(-32600, "id_mismatch")
    extra = set(params) - PARAM_KEYS[method]
    if extra:
        raise ProtocolError(-32602, "unknown_param", ", ".join(sorted(extra)))
    params = {k: v for k, v in params.items() if k != "_meta"}
    if method == "initialize":
        _check_initialize(params)
    elif method == "tools/list":
        cursor = params.get("cursor")
        if cursor is not None and (not isinstance(cursor, str) or len(cursor) > LINE_MAX):
            raise ProtocolError(-32602, "bad_cursor")
    elif method == "tools/call":
        if not isinstance(params.get("name"), str) or not TOOL_NAME.fullmatch(params["name"]):
            raise ProtocolError(-32602, "bad_tool_name")
        if not isinstance(params.get("arguments", {}), dict):
            raise ProtocolError(-32602, "bad_arguments")
    return Request(msg["id"] if "id" in msg else None, method, params)


# ── argument validation ───────────────────────────────────────────────────

def _check_value(kind, name, value, session):
    if isinstance(kind, dict):
        if value not in kind["enum"]:
            raise Deny("bad_argument", f"{name}: value not allowed")
        return
    if kind in ("line", "project"):
        if not isinstance(value, str) or len(value) > LINE_MAX or LINE_BREAKERS.search(value):
            raise Deny("bad_argument", f"{name}: must be one line of at most {LINE_MAX} characters")
        if kind == "project" and value not in session.docket_projects:
            raise Deny("project_not_allowed", name)
    elif kind == "text":
        if not isinstance(value, str) or len(value) > TEXT_MAX or TEXT_FORBIDDEN.search(value):
            raise Deny("bad_argument", f"{name}: must be text of at most {TEXT_MAX} characters")
    elif kind == "int":
        if isinstance(value, bool) or not isinstance(value, int) or abs(value) > 2**31:
            raise Deny("bad_argument", f"{name}: must be an integer")
    elif kind == "bool":
        if not isinstance(value, bool):
            raise Deny("bad_argument", f"{name}: must be a boolean")
    elif kind == "str_list":
        if not isinstance(value, list) or len(value) > LIST_MAX:
            raise Deny("bad_argument", f"{name}: must be a list of at most {LIST_MAX} strings")
        for item in value:
            _check_value("line", name, item, session)
    elif kind == "json":
        if len(strict_json.dumps(value)) > JSON_ARG_MAX:
            raise Deny("bad_argument", f"{name}: over {JSON_ARG_MAX} bytes")
    elif kind == "note_id":
        if not isinstance(value, str) or not NOTE_ID.fullmatch(value):
            raise Deny("bad_argument", f"{name}: must be a Minerva note id")
    elif kind == "ref":
        if not isinstance(value, str) or not REF.fullmatch(value):
            raise Deny("bad_argument", f"{name}: must be a full 32-hex item id")
    elif kind == "base64":
        if not isinstance(value, str) or len(value) > BASE64_MAX or not BASE64.fullmatch(value):
            raise Deny("bad_argument", f"{name}: must be base64 of at most {BASE64_MAX} characters")


def validate_arguments(spec, args, session):
    extra = set(args) - set(spec["args"])
    if extra:
        raise Deny("argument_not_allowed", ", ".join(sorted(extra)))
    for name in spec["required"]:
        if name not in args:
            raise Deny("missing_argument", name)
    for name, value in args.items():
        _check_value(spec["args"][name], name, value, session)


# ── upstream result shaping ──────────────────────────────────────────────

def result_json(result):
    """The JSON value in a successful tool result's single text block."""
    if not isinstance(result, dict) or result.get("isError"):
        raise Deny("upstream_tool_error")
    content = result.get("content")
    if not isinstance(content, list) or len(content) != 1 \
            or not isinstance(content[0], dict) or content[0].get("type") != "text" \
            or not isinstance(content[0].get("text"), str):
        raise Deny("upstream_bad_shape")
    try:
        return strict_json.loads(content[0]["text"].encode("utf-8"), MAX_RESULT_TEXT)
    except strict_json.StrictJSONError:
        raise Deny("upstream_bad_shape") from None


def json_result(value):
    """A fresh tool result carrying only value."""
    return {"content": [{"type": "text", "text": strict_json.dumps(value).decode("utf-8")}]}


def shape_passthrough(result):
    """Allowed tools whose target the gateway has already vetted: keep only
    the checked JSON value. A tool error keeps only a bounded top-level
    "error" string (the vetted item's own complaint, e.g. a bad transition);
    anything else in it is dropped."""
    if isinstance(result, dict) and result.get("isError") is True:
        content = result.get("content")
        message = "tool reported an error"
        if isinstance(content, list) and len(content) == 1 and isinstance(content[0], dict) \
                and isinstance(content[0].get("text"), str):
            try:
                value = strict_json.loads(content[0]["text"].encode("utf-8"), MAX_RESULT_TEXT)
            except strict_json.StrictJSONError:
                value = None
            if isinstance(value, dict) and isinstance(value.get("error"), str):
                message = value["error"][:ERROR_TEXT_MAX]
        return {"content": [{"type": "text", "text": strict_json.dumps({"error": message}).decode()}],
                "isError": True}
    return json_result(result_json(result))


def shape_initialize(result):
    if not isinstance(result, dict) or not isinstance(result.get("protocolVersion"), str) \
            or not PROTOCOL_VERSION.fullmatch(result["protocolVersion"]):
        raise Deny("upstream_bad_shape")
    info = result.get("serverInfo") if isinstance(result.get("serverInfo"), dict) else {}
    server_info = {k: info[k][:LINE_MAX] for k in ("name", "version") if isinstance(info.get(k), str)}
    return {"protocolVersion": result["protocolVersion"], "capabilities": {"tools": {}},
            "serverInfo": server_info or {"name": "gateway"}}


def shape_ping(result):
    return {}


def tool_schema(spec, upstream_schema):
    """The container-facing schema, generated from the policy spec. Upstream
    property descriptions are kept; nothing else of the upstream schema is."""
    upstream_props = {}
    if isinstance(upstream_schema, dict) and isinstance(upstream_schema.get("properties"), dict):
        upstream_props = upstream_schema["properties"]
    props = {}
    for name, kind in spec["args"].items():
        prop = dict(KIND_SCHEMA[kind]) if not isinstance(kind, dict) \
            else {"type": "string", "enum": list(kind["enum"])}
        described = upstream_props.get(name)
        if isinstance(described, dict) and isinstance(described.get("description"), str):
            prop["description"] = described["description"][:2000]
        props[name] = prop
    return {"type": "object", "properties": props, "required": list(spec["required"]),
            "additionalProperties": False}


def shape_tools_list(policy, service, result):
    """Allowed tools only, each rebuilt: name, bounded description, and the
    schema generated from the policy."""
    if not isinstance(result, dict) or not isinstance(result.get("tools"), list):
        raise Deny("upstream_bad_shape")
    allowed = policy.tools(service)
    tools = []
    for tool in result["tools"]:
        if not isinstance(tool, dict) or tool.get("name") not in allowed:
            continue
        rebuilt = {"name": tool["name"],
                   "inputSchema": tool_schema(allowed[tool["name"]], tool.get("inputSchema"))}
        if isinstance(tool.get("description"), str):
            rebuilt["description"] = tool["description"][:4000]
        tools.append(rebuilt)
    shaped = {"tools": tools}
    if isinstance(result.get("nextCursor"), str) and len(result["nextCursor"]) <= LINE_MAX:
        shaped["nextCursor"] = result["nextCursor"]
    return shaped


# ── rules ────────────────────────────────────────────────────────────────

def _split_ref(value, project, same_project):
    ref_project, hex_id = REF.fullmatch(value).groups()
    ref_project = ref_project or project
    if same_project and ref_project != project:
        raise Deny("cross_project_ref")
    return ref_project, hex_id


def _fetch_item(ctx, project, hex_id):
    """docket_get upstream: the item, or None when Docket reports an error
    (no such item). A transport failure or a malformed answer denies."""
    try:
        result = ctx.lookup("docket_get", {"id": hex_id, "project": project, "include": []})
    except Deny:
        raise
    except Exception:
        raise Deny("lookup_failed") from None
    if isinstance(result, dict) and result.get("isError") is True:
        return None
    try:
        item = result_json(result)
    except Deny:
        raise Deny("lookup_failed") from None
    if not isinstance(item, dict) or item.get("id") != hex_id or not isinstance(item.get("type"), str):
        raise Deny("lookup_failed")
    return item


def _find_items(ctx, project, match):
    """docket_query upstream for the rows matching `match`; a project Docket
    reports an error for contributes nothing."""
    try:
        result = ctx.lookup("docket_query", {"project": project, "filter": match, "detail": "full",
                                             "limit": docket_scope.ASSIGNED_LIMIT})
    except Deny:
        raise
    except Exception:
        raise Deny("lookup_failed") from None
    if isinstance(result, dict) and result.get("isError") is True:
        return []
    value = result_json(result)
    rows = value.get("items") if isinstance(value, dict) else None
    if not isinstance(rows, list):
        raise Deny("lookup_failed")
    return rows


def _scope(ctx):
    """This call's Docket scope, from the grant record as it is now."""
    grants = ctx.session.grants()
    scope = docket_scope.Scope(grants.identity, grants.role, ctx.session.docket_projects,
                               lambda p, i: _fetch_item(ctx, p, i), lambda p, m: _find_items(ctx, p, m))
    scope.require_identity()
    return scope


def _scoped_item(ctx, scope, value, project, same_project, allowed, direct=False):
    """(canonical reference to forward, item) once the item is in scope and
    its type is allowed."""
    ref_project, hex_id = _split_ref(value, project, same_project)
    if ref_project not in ctx.session.docket_projects:
        raise Deny("project_not_allowed", "referenced project")
    item = scope.require(ref_project, hex_id, direct)
    if item.get("type") not in allowed:
        raise Deny("item_type_not_allowed")
    return (hex_id if ref_project == project else f"{ref_project}:{hex_id}"), item


def _check_references(ctx, scope, args):
    """parent and blocked_by may name only items on the session's chain, so a
    write can never pull an unrelated item into scope."""
    for field in ("parent", "blocked_by"):
        if field in args:
            args[field], _ = _scoped_item(ctx, scope, args[field], args["project"], False,
                                          ctx.policy.mutable_types)


def rule_terminal_notify(ctx, args):
    """Any harness tab except the session's own (DCR minerva:01a0dbf459c5
    comment 2202). Minerva resolves `to` and refuses a tab with no harness in
    front or one that is the reply_to terminal (code notify_self); the gateway
    refuses what it can see itself: no notify grant, no attached terminal, or
    `to` naming the attached terminal by id. There is no per-target list."""
    if not ctx.session.grants().notify:
        raise Deny("notify_not_granted", "needs the notify grant")
    binding = ctx.session.binding()
    if binding.terminal_id is None:
        raise Deny("not_attached")
    if args["to"].strip() == binding.terminal_id:
        raise Deny("notify_self", "a session does not notify its own terminal")
    if not args["text"] or len(args["text"]) > NOTIFY_TEXT_MAX:
        raise Deny("bad_argument", f"text must be 1-{NOTIFY_TEXT_MAX} characters")
    if not 0 <= args.get("wait_ms", 0) <= NOTIFY_WAIT_MAX:
        raise Deny("bad_argument", f"wait_ms must be 0-{NOTIFY_WAIT_MAX}")
    # The gateway, not the container, says who is speaking and where replies go.
    args["from"] = ctx.session.label
    args["reply_to"] = binding.terminal_id
    return Call(args, shape_passthrough)


def _require_note_grant(ctx, note_id, write):
    """Refuses a note outside the session's grants, naming the grant needed.
    Every note verb goes through here; write implies read."""
    grants = ctx.session.grants()
    if write and note_id not in grants.write:
        raise Deny("note_not_granted", "needs the note-write grant")
    if not write and note_id not in grants.read | grants.write:
        raise Deny("note_not_granted", "needs the note-read grant")


def rule_note_read(ctx, args):
    _require_note_grant(ctx, args["note_id"], write=False)

    def shape(result):
        note = result_json(result)
        if not isinstance(note, dict) or note.get("note_id") != args["note_id"] \
                or note.get("type") != "TEXT" or not isinstance(note.get("content"), str) \
                or not isinstance(note.get("title"), str):
            raise Deny("note_not_available")
        shaped = {"success": True, "note_id": note["note_id"], "title": note["title"],
                  "content": note["content"]}
        # revision feeds update_note's if_revision; passed only when it is an integer.
        revision = note.get("revision")
        if isinstance(revision, int) and not isinstance(revision, bool):
            shaped["revision"] = revision
        return json_result(shaped)
    return Call(args, shape)


def rule_note_read_since(ctx, args):
    _require_note_grant(ctx, args["note_id"], write=False)
    return Call(args, shape_passthrough)


def rule_note_write(ctx, args):
    _require_note_grant(ctx, args["note_id"], write=True)
    return Call(args, shape_passthrough)


def rule_note_append(ctx, args):
    _require_note_grant(ctx, args["note_id"], write=True)
    # The gateway, not the container, says who wrote the entry.
    args["author"] = ctx.session.label
    return Call(args, shape_passthrough)


def rule_terminal_list(ctx, args):
    """While attached: the session's own terminal and, when it holds the
    notify grant, every terminal with a harness in front (the tabs it may
    notify, including ones opened after it started). Unattached, or any other
    terminal: nothing."""
    own = ctx.session.binding().terminal_id
    may_notify = own is not None and ctx.session.grants().notify

    def shape(result):
        listing = result_json(result)
        terminals = listing.get("terminals") if isinstance(listing, dict) else None
        if not isinstance(terminals, list):
            raise Deny("upstream_bad_shape")
        kept = []
        for entry in terminals:
            if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
                raise Deny("upstream_bad_shape")
            has_harness = isinstance(entry.get("harness"), str) and entry["harness"] != ""
            if (own is not None and entry["id"] == own) or (may_notify and has_harness):
                kept.append({k: entry[k][:LINE_MAX] for k in ("id", "name", "harness", "identity", "role")
                             if isinstance(entry.get(k), str)})
        return json_result({"success": True, "terminals": kept, "count": len(kept)})
    return Call(args, shape)


def rule_orchview_view(ctx, args):
    """The orchestration viewer's verbs, evaluated for the session: the gateway
    stamps `caller` and `caller_role` with the identity and role Minerva
    registered for it (the policy spec offers neither to the container), and
    the answer must say it was evaluated for that identity as a restricted
    view, or it is refused."""
    grants = ctx.session.grants()
    if not grants.identity:
        raise Deny("docket_out_of_scope", "no session identity is registered, so no work is in view")
    args["caller"] = grants.identity
    if grants.role:
        args["caller_role"] = grants.role

    def shape(result):
        if isinstance(result, dict) and result.get("isError") is True:
            return shape_passthrough(result)
        value = result_json(result)
        identity = value.get("identity") if isinstance(value, dict) else None
        if not isinstance(identity, dict) or identity.get("principal") != grants.identity \
                or value.get("scope") != "restricted":
            raise Deny("upstream_bad_shape", "the view was not evaluated for this session")
        return json_result(value)
    return Call(args, shape)


def rule_docket_get(ctx, args):
    _, hex_id = _split_ref(args["id"], args["project"], True)
    args["id"] = hex_id
    if not set(args.get("include", [])) <= {"events", "links"}:
        raise Deny("bad_argument", "include: value not allowed")
    _scope(ctx).require(args["project"], hex_id)

    def shape(result):
        item = result_json(result)  # an upstream error denies without detail
        if not isinstance(item, dict) or item.get("id") != hex_id \
                or item.get("type") not in ctx.policy.readable_types:
            raise Deny("item_not_available")
        return json_result(item)
    return Call(args, shape)


def rule_docket_query(ctx, args):
    """The container's own filter runs upstream; only rows on its chain in
    that project come back."""
    args["detail"] = "full"  # lean rows carry no type, so they could not be filtered
    if not 1 <= args.get("limit", 50) <= QUERY_LIMIT_MAX:
        raise Deny("bad_argument", f"limit must be 1-{QUERY_LIMIT_MAX}")
    args.setdefault("limit", 50)
    chain = _scope(ctx).chain()

    def shape(result):
        value = result_json(result)
        items = value.get("items") if isinstance(value, dict) else None
        if not isinstance(items, list):
            raise Deny("upstream_bad_shape")
        kept = []
        for item in items:
            if not isinstance(item, dict) or not isinstance(item.get("type"), str):
                raise Deny("upstream_bad_shape")
            if item["type"] in ctx.policy.readable_types and (args["project"], item.get("id")) in chain:
                kept.append(item)
        return json_result({"count": len(kept), "items": kept})
    return Call(args, shape)


def rule_docket_comment(ctx, args):
    # Replies and accept/reject are not offered: nothing here could check that
    # a comment id belongs to the vetted item. Checked here as well as in
    # policy.json, so widening the data alone cannot enable them.
    if args["action"] not in ("list", "add"):
        raise Deny("bad_argument", "action not allowed")
    allowed = ctx.policy.readable_types if args["action"] == "list" else ctx.policy.mutable_types
    args["item_id"], _ = _scoped_item(ctx, _scope(ctx), args["item_id"], args["project"], True, allowed)
    if args["action"] == "list":
        if "text" in args:
            raise Deny("bad_argument", "list takes no text")
        return Call(args, shape_passthrough)
    if "text" not in args:
        raise Deny("missing_argument", "text")
    args["author"] = ctx.session.label
    return Call(args, shape_passthrough)


def rule_docket_attach(ctx, args):
    """Evidence: a file attached to an item on the session's chain."""
    args["item_id"], _ = _scoped_item(ctx, _scope(ctx), args["item_id"], args["project"], True,
                                      ctx.policy.mutable_types)
    return Call(args, shape_passthrough)


def rule_docket_detach(ctx, args):
    """list names the item; get names only an attachment id, so its answer is
    checked: the attachment's item must be on the session's chain."""
    scope = _scope(ctx)
    if args["action"] == "list":
        if "attachment_id" in args or "item_id" not in args:
            raise Deny("bad_argument", "list takes item_id only")
        args["item_id"], _ = _scoped_item(ctx, scope, args["item_id"], args["project"], True,
                                          ctx.policy.readable_types)
        return Call(args, shape_passthrough)
    if args["action"] != "get" or "item_id" in args or "attachment_id" not in args:
        raise Deny("bad_argument", "get takes attachment_id only")

    def shape(result):
        attachment = result_json(result)
        owner = attachment.get("item_id") if isinstance(attachment, dict) else None
        if not isinstance(owner, str) or scope.reach(args["project"], owner) is None:
            raise Deny("docket_out_of_scope")
        return json_result(attachment)
    return Call(args, shape)


def rule_docket_create(ctx, args):
    """A new item hangs under an item on the session's chain (a new attempt
    under its task, a bug under its attempt)."""
    if args["type"] not in ctx.policy.mutable_types:
        raise Deny("item_type_not_allowed")
    _check_references(ctx, _scope(ctx), args)
    return Call(args, shape_passthrough)


def _mutate(tool):
    """docket_update / docket_transition / docket_append: only on a direct
    item, as holder = the session identity; a protected change also needs the
    item's claim held by that identity. A docket_update of fact tags alone
    may also reach a chain item (docket_scope.is_fact_update)."""
    def rule(ctx, args):
        scope = _scope(ctx)
        fact = docket_scope.is_fact_update(tool, args)
        args["id"], item = _scoped_item(ctx, scope, args["id"], args["project"], True,
                                        ctx.policy.mutable_types, direct=not fact)
        if fact and not scope.is_direct(item):
            scope.require_fact_tags(item, item["id"], args["tags"])
        _check_references(ctx, scope, args)
        if docket_scope.touches_protected(tool, args, item):
            scope.require_holder(item, item["id"])
        args["holder"] = scope.identity
        return Call(args, shape_passthrough)
    return rule


def _claim_verb(stamp):
    """docket_claim / docket_release (holder) and docket_reassign (actor): on
    a direct item, always in the session identity's name. reassign offers no
    override, so a session can hand over only a claim it holds or one nobody
    holds."""
    def rule(ctx, args):
        scope = _scope(ctx)
        args["id"], _ = _scoped_item(ctx, scope, args["id"], args["project"], True,
                                     ctx.policy.mutable_types, direct=True)
        args[stamp] = scope.identity
        return Call(args, shape_passthrough)
    return rule


RULES = {
    "terminal_notify": rule_terminal_notify,
    "terminal_list": rule_terminal_list,
    "note_read": rule_note_read,
    "note_read_since": rule_note_read_since,
    "note_write": rule_note_write,
    "note_append": rule_note_append,
    "orchview_view": rule_orchview_view,
    "docket_get": rule_docket_get,
    "docket_query": rule_docket_query,
    "docket_comment": rule_docket_comment,
    "docket_create": rule_docket_create,
    "docket_attach": rule_docket_attach,
    "docket_detach": rule_docket_detach,
    "docket_update": _mutate("docket_update"),
    "docket_transition": _mutate("docket_transition"),
    "docket_append": _mutate("docket_append"),
    "docket_claim": _claim_verb("holder"),
    "docket_release": _claim_verb("holder"),
    "docket_reassign": _claim_verb("actor"),
}


@dataclass
class _Context:
    policy: Policy
    session: Session
    lookup: object


def plan_call(policy, service, session, name, arguments, lookup):
    """Decide one tools/call. lookup(tool, args) performs a side-effect-free
    upstream call on the same service and returns its result; a raised
    exception denies. Returns a Call or raises Deny."""
    spec = policy.tools(service).get(name)
    if spec is None:
        raise Deny("tool_not_allowed", name)
    args = json.loads(json.dumps(arguments))  # private copy the rules may rewrite
    validate_arguments(spec, args, session)
    rule = spec.get("rule")
    if rule is None:
        return Call(args, shape_passthrough)
    try:
        return RULES[rule](_Context(policy, session, lookup), args)
    except docket_scope.Refused as exc:
        raise Deny(exc.code, exc.detail) from None
