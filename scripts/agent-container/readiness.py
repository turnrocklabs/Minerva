"""Read-only inspection of an agent session for agent.py's `info` and
`readiness` commands.

Toolchain profiles (profiles.json beside this file) name the tools a session
needs and, optionally, each tool's minimum version and the arguments that
print it. A profile may extend another; its tools are laid over the base's.

What the session actually has is measured inside its running dev container
with one `docker exec` of a bash probe that sources the harness's own shell
environment (agent-env.sh), so PATH is the one the harness sees. The probe
only resolves tools, runs their version commands, tests that folders exist
and asks git for the author identity; it starts no application, test suite
or container. Docket projects are checked on the host against the Docket
service the gateway forwards to (gateway/gateway.json), with the read-only
docket_project_list call; its tools/list says whether that Docket build has
the W1 claim verbs the gateway's scoped protected writes rely on.
"""
import json
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
PROFILES = HERE / "profiles.json"
DEFAULT_PROFILE = "default"
ENV_SCRIPT = "/opt/minerva-agent/agent-env.sh"
PROBE_TIMEOUT_S = 90
TOOL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}")
VERSION_ARGS = re.compile(r"-{0,2}[A-Za-z0-9][A-Za-z0-9-]*( -{0,2}[A-Za-z0-9][A-Za-z0-9-]*){0,3}")
MIN_VERSION = re.compile(r"\d+(\.\d+){0,3}")
VERSION_IN_OUTPUT = re.compile(r"\d+(?:\.\d+)+|\d+")
IDENT = re.compile(r"^(.*?) <([^<>]*)>")
MAX_FIELD = 300

# Arguments: the start folder, then dir=PATH and tool=NAME[ ARGS] words.
# Output: tab-separated lines — ident, dir PATH yes|no, tool NAME PATH LINE.
PROBE = r'''
. "$MINERVA_PROBE_ENV" >/dev/null 2>&1
cd -- "$1" 2>/dev/null
shift
printf 'ident\t%s\n' "$(git var GIT_AUTHOR_IDENT 2>/dev/null | head -n 1)"
for word in "$@"; do
	case "$word" in
	dir=*)
		d="${word#dir=}"
		if [ -d "$d" ]; then printf 'dir\t%s\tyes\n' "$d"; else printf 'dir\t%s\tno\n' "$d"; fi ;;
	tool=*)
		spec="${word#tool=}"; t="${spec%% *}"; a=""
		[ "$t" != "$spec" ] && a="${spec#* }"
		p="$(type -P -- "$t")" || { printf 'tool\t%s\t\t\n' "$t"; continue; }
		v="$(timeout 20 "$p" $a </dev/null 2>&1 | head -n 1)"
		printf 'tool\t%s\t%s\t%s\n' "$t" "$p" "$v" ;;
	esac
done
'''


class ProfileError(ValueError):
    """profiles.json is unreadable or does not name the profile asked for."""


def profile_names():
    return sorted(_profiles())


def _profiles():
    try:
        data = json.loads(PROFILES.read_text())
    except (OSError, ValueError) as exc:
        raise ProfileError(f"{PROFILES} is unreadable: {exc}")
    if not isinstance(data, dict):
        raise ProfileError(f"{PROFILES} must hold an object of profiles")
    return data


def load_profile(name):
    """{"name", "description", "tools": {tool: {"min", "version_args"}}}."""
    profiles = _profiles()
    chain, current = [], name
    while current:
        if current in chain:
            raise ProfileError(f"profile {name} extends itself through {current}")
        entry = profiles.get(current)
        if not isinstance(entry, dict) or not isinstance(entry.get("tools", {}), dict):
            raise ProfileError(f"no toolchain profile {current!r}; profiles: {', '.join(sorted(profiles))}")
        chain.append(current)
        current = entry.get("extends", "")
    tools = {}
    for layer in reversed(chain):
        for tool, spec in profiles[layer].get("tools", {}).items():
            spec = spec if isinstance(spec, dict) else {}
            minimum = str(spec.get("min", ""))
            args = str(spec.get("version_args", "--version"))
            if not TOOL.fullmatch(tool) or (minimum and not MIN_VERSION.fullmatch(minimum)) \
                    or not VERSION_ARGS.fullmatch(args):
                raise ProfileError(f"profile {layer}: bad entry for tool {tool!r}")
            tools[tool] = {"min": minimum, "version_args": args}
    return {"name": name, "description": str(profiles[name].get("description", "")), "tools": tools}


def with_harness(profile, harness):
    """The profile's tools plus the session's harness CLI, which every session needs."""
    tools = dict(profile["tools"])
    tools.setdefault(harness, {"min": "", "version_args": "--version"})
    return tools


def probe(container, start_in, dirs, tools):
    """Measure inside the running container. Returns {"identity": {...},
    "dirs": {path: bool}, "tools": {name: {"path", "output"}}}, or
    {"error": "..."} when docker could not run the probe."""
    words = [f"dir={d}" for d in dirs]
    words += [f"tool={t} {spec['version_args']}" for t, spec in tools.items()]
    try:
        run = subprocess.run(["docker", "exec", "-e", f"MINERVA_PROBE_ENV={ENV_SCRIPT}", container,
                              "bash", "-c", PROBE, "probe", start_in, *words],
                             capture_output=True, text=True, timeout=PROBE_TIMEOUT_S)
    except FileNotFoundError:
        return {"error": "docker was not found"}
    except subprocess.TimeoutExpired:
        return {"error": f"the probe did not finish within {PROBE_TIMEOUT_S} s"}
    if run.returncode != 0 and not run.stdout:
        return {"error": (run.stderr.strip() or f"docker exec failed (exit {run.returncode})")[:MAX_FIELD]}
    found = {"identity": {}, "dirs": {}, "tools": {}}
    # The container is untrusted: its output is only ever data, and bounded.
    for line in run.stdout.splitlines():
        fields = line.split("\t")
        if fields[0] == "ident" and len(fields) == 2:
            found["identity"] = git_identity(fields[1])
        elif fields[0] == "dir" and len(fields) == 3 and fields[1] in dirs:
            found["dirs"][fields[1]] = fields[2] == "yes"
        elif fields[0] == "tool" and len(fields) == 4 and fields[1] in tools:
            found["tools"][fields[1]] = {"path": fields[2][:MAX_FIELD], "output": fields[3][:MAX_FIELD]}
    return found


def git_identity(ident):
    """{"name", "email"} from `git var GIT_AUTHOR_IDENT`, or {} when git has none."""
    match = IDENT.match(ident)
    return {"name": match.group(1)[:MAX_FIELD], "email": match.group(2)[:MAX_FIELD]} if match else {}


def version_of(output):
    match = VERSION_IN_OUTPUT.search(output)
    return match.group(0) if match else ""


def at_least(found, minimum):
    def parts(text):
        return [int(p) for p in text.split(".")]
    a, b = parts(found), parts(minimum)
    width = max(len(a), len(b))
    return a + [0] * (width - len(a)) >= b + [0] * (width - len(b))


CLAIM_VERBS = ("docket_claim", "docket_release", "docket_reassign")


def _docket(method, params):
    """One read-only request to the Docket service the gateway forwards to:
    (result, "") or (None, why it could not be asked)."""
    gateway = str(HERE / "gateway")
    sys.path.insert(0, gateway)
    try:
        import mcp_http  # the gateway's own upstream client
    finally:
        sys.path.remove(gateway)
    try:
        config = json.loads((HERE / "gateway" / "gateway.json").read_text())
        upstream = mcp_http.Upstream.parse(config["upstreams"]["docket"])
        reply, _ = mcp_http.call_upstream(upstream, {"jsonrpc": "2.0", "id": 1, "method": method,
                                                     "params": params}, {}, deadline_s=15)
    except mcp_http.UpstreamError as exc:
        return None, f"the Docket service could not be asked ({exc})"
    except (OSError, ValueError, KeyError) as exc:
        return None, f"the Docket service could not be asked ({type(exc).__name__})"
    result = reply.get("result") if isinstance(reply, dict) else None
    return (result, "") if isinstance(result, dict) else (None, "the Docket service gave no result")


def docket_projects():
    """(names the Docket service knows, "") or (None, why it could not be asked)."""
    result, error = _docket("tools/call", {"name": "docket_project_list", "arguments": {}})
    if result is None:
        return None, error
    try:
        text = result["content"][0]["text"] if not result.get("isError") else ""
        listed = json.loads(text).get("projects") if text else None
    except (ValueError, KeyError, IndexError, TypeError, AttributeError) as exc:
        return None, f"the Docket service gave no project list ({type(exc).__name__})"
    if not isinstance(listed, list):
        return None, "the Docket service did not list its projects"
    return {str(p.get("name", "")) for p in listed if isinstance(p, dict)}, ""


def docket_claims():
    """(True, detail) when the Docket service offers the claim verbs and
    docket_update takes `holder`; (False, what is missing or why it could
    not be asked) otherwise. Read from its tools/list."""
    result, error = _docket("tools/list", {})
    if result is None:
        return False, error
    tools = {t.get("name"): t for t in result.get("tools", []) if isinstance(t, dict)} \
        if isinstance(result.get("tools"), list) else {}
    schema = tools.get("docket_update", {}).get("inputSchema", {})
    props = schema.get("properties", {}) if isinstance(schema, dict) else {}
    missing = [v for v in CLAIM_VERBS if v not in tools]
    if not isinstance(props, dict) or "holder" not in props:
        missing.append("docket_update holder")
    if missing:
        return False, (f"this Docket build lacks {', '.join(missing)}: the session can read and add "
                       "evidence to its assigned work, but its claims and protected-field changes are "
                       "refused until the Docket app is updated")
    return True, "the Docket service offers docket_claim/release/reassign and holder on writes"


def checks(record, running, measured, tools, known_projects, docket_error, claims=None):
    """Every readiness check as {"check", "name", "ok", "detail"}."""
    out = []

    def add(kind, name, ok, detail):
        out.append({"check": kind, "name": name, "ok": ok, "detail": detail})

    add("session", "running", running,
        "the dev container is running" if running else
        "the session is not running: tools, folders and the Git identity are measured inside it")
    if running and "error" in measured:
        add("session", "probe", False, measured["error"])
    elif running:
        for tool, spec in tools.items():
            seen = measured["tools"].get(tool, {})
            if not seen.get("path"):
                add("tool", tool, False, "not found on the harness's PATH")
                continue
            version = version_of(seen.get("output", ""))
            if spec["min"] and not version:
                add("tool", tool, False, f"{seen['path']}: no version in {seen.get('output', '')!r}; "
                                         f"the profile needs {spec['min']} or later")
            elif spec["min"] and not at_least(version, spec["min"]):
                add("tool", tool, False, f"{version} is below the profile's minimum {spec['min']}")
            else:
                add("tool", tool, True, f"{version or 'present'} at {seen['path']}")
        for folder in record["folders"]:
            visible = measured["dirs"].get(folder["path"], False)
            add("folder", folder["path"], visible,
                f"the harness sees {folder['host'] or folder['path']} here" if visible
                else "not visible inside the container")
        ident = measured["identity"]
        add("git_identity", "author", bool(ident),
            f"{ident['name']} <{ident['email']}>" if ident else
            "git has no author identity in the start folder: commits fail")
    for project in record["projects"]:
        if known_projects is None:
            add("docket", project, False, docket_error)
        else:
            add("docket", project, project in known_projects,
                "loaded by the Docket service" if project in known_projects
                else "the Docket service has no project by this name")
    if claims is not None:
        add("docket", "claim verbs", claims[0], claims[1])
    return out
