class_name ToolchainRegistry
extends RefCounted
## Toolchain resolution + preflight for the plugin `setup` pipeline
## (DCR 019f69428fa0, contract: Docs/design/plugin-setup-pipeline.md §2).
##
## Owns the v1 tool registry data (candidate exe names, version argv/regex,
## well-known install dirs, install hints) and the resolution algorithm:
## persisted user override → well-known dirs → PATH, shim-rejected before
## execution, execution+parse is the only pass condition (see ToolchainProbe
## for the low-level probe mechanics). Resolved paths are persisted
## machine-locally via a standalone ConfigFile so repeat installs don't
## re-walk the filesystem every time.
##
## THREADING: resolve()/preflight() are synchronous and busy-wait on probe
## subprocesses (up to 5s per candidate, N tools per preflight) — callers on
## the main thread WILL freeze the UI. The installer must run preflight from
## a worker thread (it owns S_BUILDING threading; see contract §3).
##
## Persistence choice: standalone ConfigFile at `user://toolchain_paths.cfg`,
## not SingletonObject.config_file. This mirrors DocketManager's
## `user://docket_projects.cfg` pattern (a small dedicated registry file
## loaded/saved directly by the owning service) rather than
## PluginSettingsStore's approach (routes through SingletonObject's shared
## config + a settings-schema UI layer). A Setup-layer class has no business
## depending on SingletonObject — it must be usable from a headless test
## SceneTree with no autoloads and no UI, and toolchain paths are pure
## machine-local plumbing, not a user-facing preference.
##
## Test/injection seams (both instance-level, empty/default = production
## behavior):
##   search_dirs_override — if non-empty, REPLACES well-known-dirs+PATH
##     entirely for resolve()'s full-resolution search. Lets tests point at
##     a fixture-only search space without depending on (or polluting) the
##     host's real PATH or install dirs.
##   config_path — persistence target. Tests use a scratch user:// path so
##     runs don't read/write the real toolchain_paths.cfg.

const CONFIG_PATH_DEFAULT := "user://toolchain_paths.cfg"
const CONFIG_SECTION := "toolchain_paths"

## v1 registry data. Each entry:
##   candidates    — exe basenames to try, in order (e.g. python → python, python3).
##   version_args  — argv (excluding the exe itself) that prints a version string.
##   version_regex — RegEx pattern; capture groups 1-3 are major/minor/patch.
##   install_hint  — URL shown to the user in the preflight envelope.
##   well_known    — OS.get_name() → Array[String] of install-dir templates.
##     "{HOME}" and "{USERPROFILE}" are expanded via OS.get_environment() at
##     resolve time — never passed through unexpanded.
const TOOLS := {
	"go": {
		"candidates": ["go"],
		"version_args": ["version"],
		"version_regex": "go(\\d+)\\.(\\d+)(?:\\.(\\d+))?",
		"install_hint": "https://go.dev/dl",
		"well_known": {
			"Linux": ["/usr/local/go/bin", "{HOME}/go/bin"],
			"macOS": ["/usr/local/go/bin", "{HOME}/go/bin", "/opt/homebrew/bin"],
			"Windows": ["{USERPROFILE}\\go\\bin"],
		},
	},
	"cargo": {
		"candidates": ["cargo"],
		"version_args": ["--version"],
		"version_regex": "cargo (\\d+)\\.(\\d+)\\.(\\d+)",
		"install_hint": "https://rustup.rs",
		"well_known": {
			"Linux": ["{HOME}/.cargo/bin"],
			"macOS": ["{HOME}/.cargo/bin", "/opt/homebrew/bin"],
			"Windows": ["{USERPROFILE}\\.cargo\\bin"],
		},
	},
	"python": {
		"candidates": ["python", "python3"],
		"version_args": ["--version"],
		"version_regex": "Python (\\d+)\\.(\\d+)\\.(\\d+)",
		"install_hint": "https://www.python.org/downloads/",
		"well_known": {
			"Linux": ["{HOME}/anaconda3/bin", "{HOME}/miniconda3/bin", "/opt/conda/bin"],
			"macOS": ["{HOME}/anaconda3/bin", "{HOME}/miniconda3/bin", "/opt/conda/bin", "/opt/homebrew/bin"],
			"Windows": ["{USERPROFILE}\\anaconda3", "{USERPROFILE}\\miniconda3"],
		},
	},
	"node": {
		"candidates": ["node"],
		"version_args": ["--version"],
		"version_regex": "v(\\d+)\\.(\\d+)\\.(\\d+)",
		"install_hint": "https://nodejs.org/en/download",
		"well_known": {
			"Linux": ["/usr/local/bin"],
			"macOS": ["/opt/homebrew/bin", "/usr/local/bin"],
			"Windows": ["{USERPROFILE}\\AppData\\Roaming\\npm"],
		},
	},
	"bun": {
		"candidates": ["bun"],
		"version_args": ["--version"],
		"version_regex": "(\\d+)\\.(\\d+)\\.(\\d+)",
		"install_hint": "https://bun.sh",
		"well_known": {
			"Linux": ["{HOME}/.bun/bin"],
			"macOS": ["{HOME}/.bun/bin", "/opt/homebrew/bin"],
			"Windows": ["{USERPROFILE}\\.bun\\bin"],
		},
	},
	"zig": {
		"candidates": ["zig"],
		"version_args": ["version"],
		"version_regex": "(\\d+)\\.(\\d+)\\.(\\d+)",
		"install_hint": "https://ziglang.org/download/",
		"well_known": {
			"Linux": ["{HOME}/.local/zig", "/usr/local/zig"],
			"macOS": ["{HOME}/.local/zig", "/opt/homebrew/bin"],
			"Windows": ["{USERPROFILE}\\zig"],
		},
	},
	"scons": {
		"candidates": ["scons"],
		"version_args": ["--version"],
		"version_regex": "v(\\d+)\\.(\\d+)\\.(\\d+)",
		"install_hint": "https://scons.org/pages/download.html",
		"well_known": {
			"Linux": ["{HOME}/.local/bin"],
			"macOS": ["{HOME}/.local/bin", "/opt/homebrew/bin"],
			"Windows": ["{USERPROFILE}\\AppData\\Roaming\\Python\\Scripts"],
		},
	},
}

## Test/injection seams — see class doc. Empty = production behavior.
var search_dirs_override: Array[String] = []
var config_path: String = CONFIG_PATH_DEFAULT


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Resolves `tool` to an absolute, version-checked executable path.
## Resolution order: persisted sticky path (re-probed cheaply; falls through
## to full resolution if it no longer probes good) → well-known dirs → PATH
## (or search_dirs_override in its place, for tests).
##
## Success: {"ok": true, "tool": tool, "path": <abs path>, "version": <str>}
## Failure: preflight error envelope (see _fail_envelope), one of
##   toolchain_missing | toolchain_too_old | toolchain_shim_rejected | toolchain_probe_failed
func resolve(tool: String, min_version: String) -> Dictionary:
	if not TOOLS.has(tool):
		push_error("ToolchainRegistry.resolve: unknown tool '%s'" % tool)
		return _fail_envelope(tool, "toolchain_missing", "", "", min_version)

	var entry: Dictionary = TOOLS[tool]

	var persisted := _load_persisted_path(tool)
	if persisted != "":
		var sticky := ToolchainProbe.probe(persisted, entry["version_args"],
				entry["version_regex"], min_version)
		if sticky.get("ok", false):
			return _ok_envelope(tool, persisted, sticky["version"])
		# Sticky path no longer probes good (removed, broken, etc.) — fall
		# through to a full resolution rather than erroring on a stale cache.

	var candidates := _candidate_paths(tool)

	var best_too_old: Dictionary = {}
	var any_probe_failed := false
	var any_shim := false

	for cand in candidates:
		if not FileAccess.file_exists(cand):
			continue
		if ToolchainProbe.is_shim(cand):
			any_shim = true
			continue
		var r := ToolchainProbe.probe(cand, entry["version_args"], entry["version_regex"], min_version)
		if r.get("ok", false):
			_persist_path(tool, cand)
			return _ok_envelope(tool, cand, r["version"])
		elif r.get("error", "") == "toolchain_too_old":
			if best_too_old.is_empty():
				best_too_old = {"path": cand, "version": r["version"]}
		elif r.get("error", "") == "toolchain_probe_failed":
			any_probe_failed = true

	if not best_too_old.is_empty():
		return _fail_envelope(tool, "toolchain_too_old", best_too_old["path"], best_too_old["version"], min_version)
	if any_probe_failed:
		return _fail_envelope(tool, "toolchain_probe_failed", "", "", min_version)
	if any_shim:
		return _fail_envelope(tool, "toolchain_shim_rejected", "", "", min_version)
	return _fail_envelope(tool, "toolchain_missing", "", "", min_version)


## Clears the persisted sticky path for `tool` (the Rebuild / re-check hook).
## Next resolve() call performs a full resolution regardless of any cached path.
func invalidate(tool: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(config_path) != OK:
		return
	if cfg.has_section_key(CONFIG_SECTION, tool):
		cfg.erase_section_key(CONFIG_SECTION, tool)
		cfg.save(config_path)


## Evaluates every requirement and returns ALL failures at once (never stops
## at the first one — the user should see every missing tool in one pass).
## `requires` is an Array of {"tool": String, "min": String} dicts (the
## manifest `setup.requires` shape, contract §1).
## Returns {"ok": bool, "failures": Array[envelope], "resolved": {tool: path}}.
func preflight(requires: Array) -> Dictionary:
	var failures: Array = []
	var resolved: Dictionary = {}
	for req in requires:
		var tool: String = req.get("tool", "")
		var min_version: String = req.get("min", "0")
		var r := resolve(tool, min_version)
		if r.get("ok", false):
			resolved[tool] = r["path"]
		else:
			failures.append(r)
	return {"ok": failures.is_empty(), "failures": failures, "resolved": resolved}


# ---------------------------------------------------------------------------
# Candidate search space
# ---------------------------------------------------------------------------

func _candidate_paths(tool: String) -> Array[String]:
	var dirs: Array[String]
	if not search_dirs_override.is_empty():
		dirs = search_dirs_override
	else:
		dirs = _well_known_dirs(tool)
		dirs.append_array(_path_dirs())

	var names := _candidate_names(tool)
	var out: Array[String] = []
	var seen := {}
	for d in dirs:
		if d == "":
			continue
		for n in names:
			var full: String = d.path_join(n)
			if not seen.has(full):
				seen[full] = true
				out.append(full)
	return out


func _candidate_names(tool: String) -> Array[String]:
	var names: Array = TOOLS[tool]["candidates"]
	var out: Array[String] = []
	for n in names:
		out.append(String(n))
	if OS.get_name() == "Windows":
		var with_ext: Array[String] = []
		for n in out:
			with_ext.append(n + ".exe")
			with_ext.append(n)
		return with_ext
	return out


## Expands this tool's well-known install-dir templates for the current OS,
## substituting {HOME} / {USERPROFILE} via OS.get_environment() ourselves —
## no env-var expansion is ever handed to a subprocess or left unexpanded.
func _well_known_dirs(tool: String) -> Array[String]:
	var entry: Dictionary = TOOLS[tool]
	var os_name := OS.get_name()
	var well_known: Dictionary = entry.get("well_known", {})
	var templates: Array = well_known.get(os_name, [])
	if templates.is_empty() and os_name != "Windows":
		# Unusual unix flavor (BSD, etc.) — Linux's dir shape is the closest fit.
		templates = well_known.get("Linux", [])

	var home := OS.get_environment("HOME")
	var userprofile := OS.get_environment("USERPROFILE")
	if home == "":
		home = userprofile

	var out: Array[String] = []
	for t in templates:
		var expanded: String = String(t).replace("{HOME}", home).replace("{USERPROFILE}", userprofile)
		out.append(expanded)
	return out


func _path_dirs() -> Array[String]:
	var sep := ";" if OS.get_name() == "Windows" else ":"
	var raw := OS.get_environment("PATH")
	if raw == "":
		return []
	var out: Array[String] = []
	for p in raw.split(sep):
		if p != "":
			out.append(p)
	return out


# ---------------------------------------------------------------------------
# Persistence (standalone ConfigFile — see class doc)
# ---------------------------------------------------------------------------

func _load_persisted_path(tool: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(config_path) != OK:
		return ""
	return String(cfg.get_value(CONFIG_SECTION, tool, ""))


func _persist_path(tool: String, path: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(config_path)  # OK to ignore error — file may not exist yet.
	cfg.set_value(CONFIG_SECTION, tool, path)
	cfg.save(config_path)


# ---------------------------------------------------------------------------
# Envelope builders
# ---------------------------------------------------------------------------

func _ok_envelope(tool: String, path: String, version: String) -> Dictionary:
	return {"ok": true, "tool": tool, "path": path, "version": version}


## Preflight error envelope, contract §2 field names exactly:
## error, tool, found_path, found_version, required_min, install_hint.
func _fail_envelope(tool: String, error: String, found_path: String,
		found_version: String, required_min: String) -> Dictionary:
	var install_hint := ""
	if TOOLS.has(tool):
		install_hint = TOOLS[tool]["install_hint"]
	return {
		"ok": false,
		"error": error,
		"tool": tool,
		"found_path": found_path,
		"found_version": found_version,
		"required_min": required_min,
		"install_hint": install_hint,
	}
