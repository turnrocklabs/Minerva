"""Which Docket items a container session may touch, decided on every call
from the current records (mcp_policy.py's docket rules build one Scope per
call; nothing is cached between calls).

The scope rule. A session's principals are the identity and role Minerva
registered for it (HarnessSessionRegistry), which Minerva writes into the
session's grant record (control/grants.json) beside its note grants. An item
is DIRECT when its `assigned_to` or `directed_to` equals one of those
principals exactly. The session's CHAIN is every direct item in its Docket
projects plus each one's parents, walked up to and including the first item
tagged `wr:objective` (at most ANCESTOR_DEPTH levels, never into a project
the session does not have). The session may read items on its chain, list
their comments and attachments, and add evidence (comments, attachments) to
them. It may change fields only on direct items, always as `holder` = its
identity, and a change that touches a protected field (W1 contract, KB
docket:01a0dc3549bc section 4) additionally needs the item's claim to be held
by that identity. Nothing else is in scope: with no registered identity,
nothing is.
"""
import re

PARENT = re.compile(r"(?:([A-Za-z0-9._-]{1,64}):)?([0-9a-f]{32})")
PROTECTED_FIELDS = frozenset({"status", "resolution", "assigned_to", "parent", "blocked_by",
                              "title", "description"})
PROTECTED_TAG_PREFIXES = ("wr:", "role:", "base:", "head:", "result:", "requires:", "outcome:",
                          "deferred:")
OBJECTIVE_TAG = "wr:objective"
ANCESTOR_DEPTH = 8
ASSIGNED_LIMIT = 200

DIRECT, CHAIN = "direct", "chain"


class Refused(Exception):
    """An item outside the session's scope, or a protected write it may not
    make. code is fixed; detail names the item and the scope."""

    def __init__(self, code, detail):
        self.code, self.detail = code, detail
        super().__init__(f"{code}: {detail}")


class Scope:
    """One call's view of what the session may touch.

    fetch(project, hex_id) returns the item as docket_get answers it, or
    None when Docket has no such item; find(project, filter) returns the rows
    of a docket_query. Both may raise to deny the whole call."""

    def __init__(self, identity, role, projects, fetch, find):
        self.identity, self.role, self.projects = identity, role, frozenset(projects)
        self._fetch, self._find = fetch, find
        self._items = {}
        self._chain = None

    @property
    def principals(self):
        return tuple(p for p in (self.identity, self.role) if p)

    def _who(self):
        return self.identity + (f" or role {self.role}" if self.role else "")

    def require_identity(self):
        if not self.identity:
            raise Refused("docket_out_of_scope",
                          "no session identity is registered, so no Docket work is assigned to this session")

    def item(self, project, hex_id):
        key = (project, hex_id)
        if key not in self._items:
            self._items[key] = self._fetch(project, hex_id)
        return self._items[key]

    def is_direct(self, item):
        return isinstance(item, dict) and any(
            item.get(field) in self.principals for field in ("assigned_to", "directed_to"))

    def chain(self):
        """{(project, hex_id): DIRECT or CHAIN} for every item on the chain."""
        if self._chain is not None:
            return self._chain
        found = {}
        if self.principals:
            match = {"$or": [{"field": field, "op": "eq", "value": p}
                             for p in self.principals for field in ("assigned_to", "directed_to")]}
            rows = []
            for project in sorted(self.projects):
                for row in self._find(project, match)[:ASSIGNED_LIMIT]:
                    if isinstance(row, dict) and isinstance(row.get("id"), str) and self.is_direct(row):
                        found[(project, row["id"])] = DIRECT
                        rows.append((project, row))
            # Query rows carry parent and tags but not claim_holder, so they
            # seed the walk and are never kept as the item itself.
            for project, row in rows:
                self._walk_up(project, row, found)
        self._chain = found
        return found

    def _walk_up(self, project, item, found):
        for _ in range(ANCESTOR_DEPTH):
            if not isinstance(item, dict) or OBJECTIVE_TAG in (item.get("tags") or []):
                return
            parent = item.get("parent")
            match = PARENT.fullmatch(parent) if isinstance(parent, str) else None
            if match is None:
                return
            project = match.group(1) or project
            hex_id = match.group(2)
            if project not in self.projects:
                return
            found.setdefault((project, hex_id), CHAIN)
            item = self.item(project, hex_id)

    def reach(self, project, hex_id):
        """DIRECT, CHAIN, or None when the item is out of scope or missing."""
        if not self.principals or project not in self.projects:
            return None
        item = self.item(project, hex_id)
        if item is None:
            return None
        if self.is_direct(item):
            return DIRECT
        return self.chain().get((project, hex_id))

    def require(self, project, hex_id, direct=False):
        """The item, when the session may read it (or, with direct, change
        it); otherwise Refused naming the scope. A missing item is refused
        the same way, so a refusal never says whether an item exists."""
        self.require_identity()
        reach = self.reach(project, hex_id)
        if reach is None:
            raise Refused("docket_out_of_scope", f"item {hex_id} is not assigned to {self._who()}")
        if direct and reach != DIRECT:
            raise Refused("docket_out_of_scope",
                          f"item {hex_id} is not assigned to {self._who()} (it is only on its work chain: "
                          "read it and add comments or attachments)")
        return self.item(project, hex_id)

    def require_holder(self, item, hex_id):
        holder = item.get("claim_holder") if isinstance(item.get("claim_holder"), str) else ""
        if holder != self.identity:
            # The current holder is not named: refusal details carry no upstream data.
            raise Refused("docket_not_holder",
                          f"item {hex_id} is not claimed by {self.identity}; "
                          "protected fields change only under your claim (docket_claim)")


def touches_protected(tool, args, item):
    """Whether a docket_update / docket_transition / docket_append call would
    change a protected field of `item` (as docket_get returned it)."""
    if tool == "docket_transition":
        return True     # every transition writes status
    if tool == "docket_append":
        return args.get("field") in PROTECTED_FIELDS
    if PROTECTED_FIELDS & set(args):
        return True
    if "tags" in args:
        before = set(item.get("tags") or [])
        changed = before ^ set(args["tags"])
        return any(tag.startswith(PROTECTED_TAG_PREFIXES) for tag in changed)
    return False
