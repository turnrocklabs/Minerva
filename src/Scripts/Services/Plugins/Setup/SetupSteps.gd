class_name SetupSteps
extends RefCounted
## PURE plan builder for `setup.steps[]` entries — the single source of truth
## for what argv each step type produces. Consumed by BOTH SetupExecutors
## (real runs) and SetupDryRun (rendered plans), so the executed argv and the
## dry-run-displayed argv can never drift; test_plugin_setup_executors.gd
## asserts that parity per step type.
##
## Pure means pure: no I/O, no spawning, no OS state beyond OS.get_name()
## (needed for the venv python path, which genuinely differs per OS).
##
## Contract (Docs/design/plugin-setup-pipeline.md §1 as amended by the R1
## review): steps are CWD-INDEPENDENT. No wrapper process, no shell — the
## tool binary is spawned directly with an argv that carries any needed
## directory context itself:
##   - go_build uses go's own `-C <abs plugin_dir>` (go >= 1.20) and keeps
##     `output`/`package` relative in the argv, matching the contract example.
##   - cargo_build absolutizes --manifest-path.
##   - python_venv absolutizes the venv dir, install target, and
##     requirements path.
##   - copy is a pure filesystem op (no argv).
##   - exec gets NO cwd guarantee: argv[0] beginning with "./" is resolved
##     against plugin_dir (absolute); every remaining element is passed
##     verbatim. Exec'd programs that need the plugin dir must derive it from
##     argv[0] or accept it as an explicit argument.

const DEFAULT_TIMEOUT_S := 300

## The closed v1 step vocabulary (§1).
const STEP_TYPES := ["go_build", "cargo_build", "python_venv", "copy", "exec"]


## Builds the execution plan for ONE schema-valid step.
## step: the `setup.steps[]` entry. tool_paths: tool name -> absolute path,
## resolved by the caller (never re-resolved here). plugin_dir: absolute
## plugin data_directory.
## Returns:
##   {"phases": Array[Dictionary], "timeout_s": int}
## One phase per subprocess the step spawns (python_venv has two: venv
## create, then pip install). Each phase:
##   {"label": String ("" = unlabelled), "argv": Array[String] ([] = no
##    subprocess — copy), "artifact": String (plugin-relative expected
##    artifact; "" = no post-phase check)}
static func build(step: Dictionary, tool_paths: Dictionary, plugin_dir: String) -> Dictionary:
	var step_type: String = str(step.get("type", ""))
	var phases: Array[Dictionary] = []

	match step_type:
		"go_build":
			var pkg: String = str(step.get("package", ""))
			var output: String = str(step.get("output", ""))
			phases.append({
				"label": "",
				"argv": [_tool(tool_paths, "go"), "build", "-C", plugin_dir, "-o", output, pkg],
				"artifact": output,
			})

		"cargo_build":
			var manifest_dir: String = str(step.get("manifest_dir", ""))
			var artifact: String = str(step.get("artifact", ""))
			var profile: String = str(step.get("profile", "release"))
			var argv: Array = [
				_tool(tool_paths, "cargo"), "build",
				"--manifest-path", plugin_dir.path_join(manifest_dir).path_join("Cargo.toml"),
			]
			if profile == "release":
				argv.append("--release")
			elif profile != "debug":
				argv.append_array(["--profile", profile])
			phases.append({"label": "", "argv": argv, "artifact": artifact})

		"python_venv":
			var dir_field: String = str(step.get("dir", ""))
			var install_mode: String = str(step.get("install", ""))
			var requirements_file: String = str(step.get("requirements_file", "requirements.txt"))
			var dir_abs: String = plugin_dir.path_join(dir_field)
			var venv_abs: String = dir_abs.path_join(".venv")
			var marker_rel: String = dir_field.path_join(".venv").path_join("pyvenv.cfg")
			var venv_python: String = venv_abs.path_join(
				"Scripts/python.exe" if OS.get_name() == "Windows" else "bin/python"
			)
			var install_argv: Array = [venv_python, "-m", "pip", "install"]
			if install_mode == "editable":
				install_argv.append_array(["-e", dir_abs])
			else:
				install_argv.append_array(["-r", dir_abs.path_join(requirements_file)])
			phases.append({
				"label": "venv create",
				"argv": [_tool(tool_paths, "python"), "-m", "venv", venv_abs],
				"artifact": marker_rel,
			})
			phases.append({"label": "pip install", "argv": install_argv, "artifact": marker_rel})

		"copy":
			var from_rel: String = str(step.get("from", ""))
			var to_rel: String = str(step.get("to", ""))
			phases.append({
				"label": "copy '%s' -> '%s'" % [from_rel, to_rel],
				"argv": [],
				"artifact": to_rel,
			})

		"exec":
			var argv_raw: Array = step.get("argv", [])
			var argv: Array = []
			for i in argv_raw.size():
				var a: String = str(argv_raw[i])
				# Only argv[0] gets the "./" resolution; everything after is
				# passed verbatim — no path rewriting, no expansion of any kind.
				if i == 0 and a.begins_with("./"):
					a = plugin_dir.path_join(a.substr(2))
				argv.append(a)
			phases.append({"label": "", "argv": argv, "artifact": str(step.get("artifact", ""))})

		_:
			phases.append({"label": "unknown step type '%s'" % step_type, "argv": [], "artifact": ""})

	return {"phases": phases, "timeout_s": timeout_of(step)}


## Per-step timeout with the contract default (§1: 300s). GDScript's
## JSON.parse() returns every manifest number as float, so a manifest
## author's `"timeout_s": 60` round-trips as 60.0 — tolerate that.
static func timeout_of(step: Dictionary) -> int:
	var raw: Variant = step.get("timeout_s", DEFAULT_TIMEOUT_S)
	if raw is int or raw is float:
		var n: float = float(raw)
		if n > 0.0:
			return int(round(n))
	return DEFAULT_TIMEOUT_S


static func _tool(tool_paths: Dictionary, name: String) -> String:
	return str(tool_paths.get(name, name))
