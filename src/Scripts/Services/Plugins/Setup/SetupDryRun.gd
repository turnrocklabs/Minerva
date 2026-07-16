class_name SetupDryRun
extends RefCounted
## Deterministic renderer for a manifest's `setup` stanza.
##
## Docs/design/plugin-setup-pipeline.md §4 fixture F12 requires the rendered
## plan to be byte-identical for byte-identical inputs. This file therefore
## has zero side effects (no subprocess spawn, no filesystem I/O) — a dry
## run must be safe to call before any toolchain preflight has run and
## before a single plugin file exists on disk.
##
## Argv construction is NOT duplicated here: every rendered argv comes from
## SetupSteps.build(), the same pure builder SetupExecutors runs — so what
## the dry run displays is, by construction, exactly what a real run would
## execute. test_plugin_setup_executors.gd asserts that parity per step type.
##
## Determinism: every field is read from the step Dictionary by name (never
## via `.keys()`/`.values()` iteration order), and steps/requires are walked
## in array order — so there is no dict-iteration-order hazard to guard
## against with an explicit key sort. Golden fixtures in this round avoid the
## python_venv step type specifically because its venv-python path is
## OS.get_name()-conditional (Scripts/python.exe vs bin/python); everything
## else renders identically on every platform.

static func render(setup: Dictionary, plugin_dir: String, tool_paths: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("setup plan for %s" % plugin_dir)
	lines.append_array(_render_requires(setup.get("requires", [])))

	var steps_raw: Variant = setup.get("steps", [])
	var steps: Array = steps_raw if steps_raw is Array else []
	lines.append("steps: %d" % steps.size())
	for i in steps.size():
		var step: Variant = steps[i]
		if not (step is Dictionary):
			lines.append("  [%d] <malformed step: not a Dictionary>" % i)
			continue
		lines.append_array(_render_step(step as Dictionary, i, plugin_dir, tool_paths))

	return "\n".join(lines) + "\n"


static func _render_requires(requires_raw: Variant) -> Array[String]:
	var out: Array[String] = []
	var requires: Array = requires_raw if requires_raw is Array else []
	if requires.is_empty():
		out.append("requires: (none)")
		return out

	out.append("requires:")
	for req in requires:
		if req is Dictionary:
			var rd: Dictionary = req as Dictionary
			out.append("  - tool=%s min=%s" % [str(rd.get("tool", "")), str(rd.get("min", ""))])
		else:
			out.append("  - <malformed requires entry>")
	return out


static func _render_step(step: Dictionary, i: int, plugin_dir: String, tool_paths: Dictionary) -> Array[String]:
	var step_type: String = str(step.get("type", ""))
	var out: Array[String] = []
	out.append("  [%d] type=%s" % [i, step_type])

	var plan: Dictionary = SetupSteps.build(step, tool_paths, plugin_dir)
	for phase in plan.get("phases", []):
		var label: String = str(phase.get("label", ""))
		var argv: Array = phase.get("argv", [])
		if argv.is_empty():
			out.append("      op=%s (no subprocess)" % (label if not label.is_empty() else "filesystem"))
		elif label.is_empty():
			out.append("      argv=%s" % JSON.stringify(argv))
		else:
			out.append("      argv[%s]=%s" % [label, JSON.stringify(argv)])
		var artifact: String = str(phase.get("artifact", ""))
		if not artifact.is_empty():
			out.append("      expected_artifact=%s" % artifact)

	return out
