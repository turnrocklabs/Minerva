class_name ToolchainProbe
extends RefCounted
## Low-level, stateless toolchain probing primitives for the plugin `setup`
## pipeline (DCR 019f69428fa0, contract: Docs/design/plugin-setup-pipeline.md §2).
##
## Everything here is a pure function over explicit inputs — no registry data,
## no persistence, no candidate-search-order knowledge. ToolchainRegistry owns
## that orchestration and calls into this class per candidate path.
##
## Hard rule enforced here: presence of a file is never sufficiency. A pass
## requires executing the tool's version argv and successfully parsing a
## version out of its output, within a 5s hard deadline. Godot's OS.execute()
## has no timeout parameter and blocks the calling thread until the child
## exits, so a hung child would hang the caller forever — unusable for a
## probe that must fail fast. Instead we use OS.execute_with_pipe() (returns
## immediately with a pid + stdio/stderr FileAccess pipes) and poll
## OS.is_process_running(pid) against a wall-clock deadline (Time.get_ticks_msec),
## OS.kill()-ing the child if the deadline is exceeded. This is the same
## non-blocking-spawn-then-poll shape used elsewhere in Minerva for process
## supervision (see PluginManager's health-check loop), just applied to a
## short-lived probe instead of a long-lived server process.

## Hard timeout for a single version-probe subprocess, per contract §2.
const PROBE_TIMEOUT_MS := 5000

## How long to sleep between liveness polls while waiting on a probe child.
const POLL_INTERVAL_MS := 20


# ---------------------------------------------------------------------------
# Shim rejection
# ---------------------------------------------------------------------------

## Returns true if `path` looks like a Windows "app execution alias" shim
## (the empty stub Windows drops in .../Microsoft/WindowsApps/ for apps that
## aren't actually installed — executing it either no-ops or pops the Store).
## Must be checked and honored BEFORE the candidate is ever executed.
## Matches case-insensitively and regardless of slash style, per contract.
static func is_shim(path: String) -> bool:
	var normalized := path.to_lower().replace("\\", "/")
	return normalized.contains("/microsoft/windowsapps/")


# ---------------------------------------------------------------------------
# Timed subprocess execution
# ---------------------------------------------------------------------------

## Spawns `exe_path` with `args`, enforcing a hard `timeout_ms` wall-clock
## deadline. Returns:
##   {"spawned": bool, "timed_out": bool, "exit_code": int, "output": String}
## `spawned` is false if the OS could not create the process at all (e.g. the
## path doesn't exist or isn't executable) — that is distinct from a probe
## that ran and failed. `output` is stdout+stderr concatenated (tools are
## inconsistent about which stream they print version info to).
static func run_with_timeout(exe_path: String, args: PackedStringArray,
		timeout_ms: int = PROBE_TIMEOUT_MS) -> Dictionary:
	var result := OS.execute_with_pipe(exe_path, args)
	var pid: int = int(result.get("pid", -1))
	if pid <= 0:
		return {"spawned": false, "timed_out": false, "exit_code": -1, "output": ""}

	var deadline_ms := Time.get_ticks_msec() + timeout_ms
	var timed_out := false
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() >= deadline_ms:
			timed_out = true
			OS.kill(pid)
			break
		OS.delay_msec(POLL_INTERVAL_MS)

	var output := ""
	var stdio_file = result.get("stdio")
	if stdio_file != null:
		output += (stdio_file as FileAccess).get_as_text()
	var stderr_file = result.get("stderr")
	if stderr_file != null:
		output += (stderr_file as FileAccess).get_as_text()

	var exit_code := -1
	if not timed_out:
		exit_code = OS.get_process_exit_code(pid)

	return {"spawned": true, "timed_out": timed_out, "exit_code": exit_code, "output": output}


# ---------------------------------------------------------------------------
# Version parsing + comparison
# ---------------------------------------------------------------------------

## Extracts a "major.minor.patch" version string from `text` using `pattern`,
## a RegEx pattern whose first 1-3 capture groups are major/minor/patch
## (patch and minor may be absent — treated as 0). Returns "" if the pattern
## doesn't match anywhere in `text`.
static func parse_version(pattern: String, text: String) -> String:
	if pattern == "" or text == "":
		return ""
	var re := RegEx.new()
	if re.compile(pattern) != OK:
		return ""
	var m := re.search(text)
	if m == null:
		return ""
	var major := _group_int(m, 1)
	var minor := _group_int(m, 2)
	var patch := _group_int(m, 3)
	return "%d.%d.%d" % [major, minor, patch]


static func _group_int(m: RegExMatch, index: int) -> int:
	if index >= m.get_group_count() + 1:
		return 0
	var s := m.get_string(index)
	if s == "" or not s.is_valid_int():
		return 0
	return int(s)


## Parses "major.minor.patch" (missing segments = 0) and returns true if
## `a` < `b`. Non-numeric segments are treated as 0 — this is a semver-ish
## compare for the `major.minor[.patch]` shape used by version argv output
## and manifest `min` fields, not a full semver spec (no pre-release/build
## metadata handling — none of the v1 tools need it).
static func semver_lt(a: String, b: String) -> bool:
	var pa := _semver_parts(a)
	var pb := _semver_parts(b)
	for i in range(3):
		if pa[i] != pb[i]:
			return pa[i] < pb[i]
	return false


static func _semver_parts(v: String) -> Array:
	var parts := v.split(".")
	var out := [0, 0, 0]
	for i in range(min(3, parts.size())):
		if parts[i].is_valid_int():
			out[i] = int(parts[i])
	return out


# ---------------------------------------------------------------------------
# Combined per-candidate probe
# ---------------------------------------------------------------------------

## Runs the full probe contract against one resolved candidate path:
## shim-reject → execute-with-timeout → parse → version-compare. Callers that
## already know a path exists still go through this (the shim check here is
## a defense-in-depth second gate, not a replacement for the registry's own
## pre-execution filtering).
##
## Returns one of:
##   {"ok": true, "version": "1.22.4"}
##   {"ok": false, "error": "toolchain_shim_rejected"}
##   {"ok": false, "error": "toolchain_probe_failed", "reason": "not_spawned"|"timed_out"|"nonzero_exit"|"unparseable"}
##   {"ok": false, "error": "toolchain_too_old", "version": "1.19.0"}
static func probe(exe_path: String, version_args: Array, version_regex: String,
		min_version: String) -> Dictionary:
	if is_shim(exe_path):
		return {"ok": false, "error": "toolchain_shim_rejected"}

	var run := run_with_timeout(exe_path, PackedStringArray(version_args))
	if not run["spawned"]:
		return {"ok": false, "error": "toolchain_probe_failed", "reason": "not_spawned"}
	if run["timed_out"]:
		return {"ok": false, "error": "toolchain_probe_failed", "reason": "timed_out"}
	if run["exit_code"] != 0:
		return {"ok": false, "error": "toolchain_probe_failed", "reason": "nonzero_exit"}

	var version := parse_version(version_regex, run["output"])
	if version == "":
		return {"ok": false, "error": "toolchain_probe_failed", "reason": "unparseable"}

	if semver_lt(version, min_version):
		return {"ok": false, "error": "toolchain_too_old", "version": version}

	return {"ok": true, "version": version}
