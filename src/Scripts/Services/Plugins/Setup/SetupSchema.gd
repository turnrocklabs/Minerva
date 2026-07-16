class_name SetupSchema
extends RefCounted
## Static validation for a manifest's `setup` stanza.
##
## Docs/design/plugin-setup-pipeline.md §1 is the frozen contract this file
## implements: the step vocabulary table and the five typed error codes below
## are normative — do not rename or add codes without a design-doc update.
##
## Mirrors PluginDefinition's existing typed-dict error convention (see
## validate_class_names() / validate_capabilities()): every failure is a
## Dictionary shaped {"error": String, "detail": Dictionary}. PluginDefinition
## folds these into its plain Array[String] validate() output via
## format_error() so a bad `setup` stanza fails manifest load exactly like
## every other structural error already does.

## Step type -> required field names (contract §1 table).
const STEP_REQUIRED_FIELDS := {
	"go_build": ["package", "output"],
	"cargo_build": ["manifest_dir", "artifact"],
	"python_venv": ["dir", "install"],
	"copy": ["from", "to"],
	"exec": ["argv"],
}

## Step type -> field names holding plugin-relative paths, checked for escape.
## "artifact" (optional on every step type) and python_venv's
## "requirements_file" are handled separately since they are shared/optional
## rather than per-type required fields.
const STEP_PATH_FIELDS := {
	"go_build": ["package", "output"],
	"cargo_build": ["manifest_dir"],
	"python_venv": ["dir"],
	"copy": ["from", "to"],
	"exec": [],
}

const _SEMVER_ISH_PATTERN := "^\\d+(\\.\\d+){0,2}([-+][0-9A-Za-z.-]+)?$"


## Validate a manifest's raw `setup` Dictionary (already lax-parsed by
## PluginDefinition._from_dict_internal — no structural checks applied yet).
## Returns an Array of structured error Dictionaries; empty Array == valid.
## A missing/empty `setup` stanza is always valid (plugin ships no native
## step — GDScript-only plugins never need one).
static func validate_setup(setup: Dictionary) -> Array[Dictionary]:
	var errors: Array[Dictionary] = []
	if setup.is_empty():
		return errors

	errors.append_array(_validate_requires(setup.get("requires", [])))

	var steps_raw: Variant = setup.get("steps", [])
	if steps_raw is Array:
		var steps: Array = steps_raw as Array
		for i in steps.size():
			var step: Variant = steps[i]
			if not (step is Dictionary):
				errors.append(_err("setup_unknown_step_type", {
					"step_index": i, "reason": "step entry must be a Dictionary",
				}))
				continue
			errors.append_array(_validate_step(step as Dictionary, i))
	# A non-Array (or absent) `steps` is treated as "no steps declared" —
	# there is no dedicated error code for a malformed `steps` container
	# itself; the closed vocabulary in §1 only speaks to individual steps.

	return errors


## Render one structured error Dictionary (as returned by validate_setup())
## into the human-readable string PluginDefinition.validate() appends to its
## Array[String]. The error code is always the leading token so callers/tests
## can match on it without re-parsing detail fields.
static func format_error(e: Dictionary) -> String:
	var code: String = str(e.get("error", ""))
	var detail: Dictionary = e.get("detail", {})

	match code:
		"setup_unknown_step_type":
			return "setup_unknown_step_type: setup.steps[%s] has unknown type '%s'" % [
				str(detail.get("step_index", "?")), str(detail.get("type", "")),
			]
		"setup_step_missing_field":
			return "setup_step_missing_field: setup.steps[%s] (%s) missing required field '%s'" % [
				str(detail.get("step_index", "?")), str(detail.get("step_type", "")), str(detail.get("field", "")),
			]
		"setup_path_escape":
			return "setup_path_escape: setup.steps[%s] field '%s' escapes the plugin directory: '%s'" % [
				str(detail.get("step_index", "?")), str(detail.get("field", "")), str(detail.get("path", "")),
			]
		"setup_bad_requires":
			return "setup_bad_requires: setup.requires[%s] %s" % [
				str(detail.get("index", "?")), str(detail.get("reason", "is invalid")),
			]
		"setup_empty_argv":
			return "setup_empty_argv: setup.steps[%s] (exec) argv must be a non-empty array of non-empty strings" % [
				str(detail.get("step_index", "?")),
			]
		_:
			return "%s: %s" % [code, JSON.stringify(detail)]


# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

static func _validate_requires(requires_raw: Variant) -> Array[Dictionary]:
	var errors: Array[Dictionary] = []
	if not (requires_raw is Array):
		return errors  # absent/malformed `requires` — no steps to check against here

	var requires: Array = requires_raw as Array
	for i in requires.size():
		var entry: Variant = requires[i]
		if not (entry is Dictionary):
			errors.append(_err("setup_bad_requires", {"index": i, "reason": "entry must be a Dictionary"}))
			continue
		var rd: Dictionary = entry as Dictionary

		if not rd.has("tool") or str(rd.get("tool", "")).is_empty():
			errors.append(_err("setup_bad_requires", {"index": i, "reason": "missing 'tool'"}))

		if not rd.has("min") or str(rd.get("min", "")).is_empty():
			errors.append(_err("setup_bad_requires", {"index": i, "reason": "missing 'min'"}))
		else:
			var min_v: String = str(rd.get("min", ""))
			if not _is_semver_ish(min_v):
				errors.append(_err("setup_bad_requires", {
					"index": i, "reason": "'min' is not semver-ish: '%s'" % min_v,
				}))

	return errors


static func _validate_step(step: Dictionary, step_index: int) -> Array[Dictionary]:
	var errors: Array[Dictionary] = []
	var step_type: String = str(step.get("type", ""))

	if not STEP_REQUIRED_FIELDS.has(step_type):
		errors.append(_err("setup_unknown_step_type", {"step_index": step_index, "type": step_type}))
		return errors  # nothing else is checkable against an unknown vocabulary entry

	for field in STEP_REQUIRED_FIELDS[step_type]:
		# exec's "argv" is exempt from the blank check here: an empty array is
		# reported exactly once, as setup_empty_argv below — not doubled up
		# with setup_step_missing_field just because "empty" and "blank" both
		# describe []. A wholly absent "argv" key is still a missing field.
		if step_type == "exec" and field == "argv":
			if not step.has(field):
				errors.append(_err("setup_step_missing_field", {
					"step_index": step_index, "step_type": step_type, "field": field,
				}))
			continue
		if not step.has(field) or _is_blank(step.get(field)):
			errors.append(_err("setup_step_missing_field", {
				"step_index": step_index, "step_type": step_type, "field": field,
			}))

	if step_type == "exec":
		errors.append_array(_validate_exec_argv(step, step_index))

	# Path-escape checks: schema-known required path fields for this step type...
	for field in STEP_PATH_FIELDS.get(step_type, []):
		if step.has(field):
			var err := _check_path_escape(str(step.get(field, "")), step_index, field)
			if not err.is_empty():
				errors.append(err)

	# ...plus the two optional path fields shared/step-specific across types.
	if step.has("artifact"):
		var artifact_err := _check_path_escape(str(step.get("artifact", "")), step_index, "artifact")
		if not artifact_err.is_empty():
			errors.append(artifact_err)
	if step_type == "python_venv" and step.has("requirements_file"):
		var req_err := _check_path_escape(str(step.get("requirements_file", "")), step_index, "requirements_file")
		if not req_err.is_empty():
			errors.append(req_err)

	return errors


static func _validate_exec_argv(step: Dictionary, step_index: int) -> Array[Dictionary]:
	var errors: Array[Dictionary] = []
	if not step.has("argv"):
		return errors  # already reported by the required-field pass above

	var argv_raw: Variant = step.get("argv")
	if not (argv_raw is Array) or (argv_raw as Array).is_empty():
		errors.append(_err("setup_empty_argv", {"step_index": step_index}))
		return errors

	for a in (argv_raw as Array):
		if not (a is String) or (a as String).is_empty():
			errors.append(_err("setup_empty_argv", {"step_index": step_index}))
			break

	return errors


## Absolute paths and any `..` path segment are rejected. No env-var
## expansion happens anywhere in the pipeline — "%X%"/"$X" are literal
## characters here, never substituted, so they are not treated specially.
static func _check_path_escape(path: String, step_index: int, field: String) -> Dictionary:
	if path.is_empty():
		return {}
	if _is_absolute_path(path):
		return _err("setup_path_escape", {
			"step_index": step_index, "field": field, "path": path, "reason": "absolute path",
		})
	var normalized := path.replace("\\", "/")
	for segment in normalized.split("/"):
		if segment == "..":
			return _err("setup_path_escape", {
				"step_index": step_index, "field": field, "path": path, "reason": "'..' traversal",
			})
	return {}


static func _is_absolute_path(path: String) -> bool:
	if path.is_empty():
		return false
	if path.begins_with("/") or path.begins_with("\\"):
		return true
	if path.begins_with("res://") or path.begins_with("user://"):
		return true
	# Windows drive letter, e.g. "C:/foo" or "C:\\foo".
	if path.length() >= 2 and path[1] == ":" and path[0].to_upper() != path[0].to_lower():
		return true
	return false


static func _is_semver_ish(v: String) -> bool:
	var rx := RegEx.new()
	if rx.compile(_SEMVER_ISH_PATTERN) != OK:
		return true  # fail open on a regex compile error — never our caller's fault
	return rx.search(v) != null


static func _is_blank(v: Variant) -> bool:
	if v == null:
		return true
	if v is String:
		return (v as String).is_empty()
	if v is Array:
		return (v as Array).is_empty()
	return false


static func _err(code: String, detail: Dictionary) -> Dictionary:
	return {"error": code, "detail": detail}
