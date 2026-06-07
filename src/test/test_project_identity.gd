extends SceneTree
## Unit tests for ProjectIdentity — the stable per-project identity (project_id +
## annotation_ref_seq) backing citeable annotation refs (DCR 019e9f602391 P1).
##
## Hermetic: drives ProjectIdentity directly with an injected ConfigFile (a temp
## user:// path) and a deterministic UUID provider — no autoload, no scene tree,
## no pollution of the real config_file.cfg.
##
## Run: godot --headless --path src --script test/test_project_identity.gd

var _pass_count: int = 0
var _fail_count: int = 0

const TMP_DIR := "user://test_project_identity"


func _init() -> void:
	print("=== ProjectIdentity Tests (DCR 019e9f602391 P1) ===\n")
	_clean_tmp()

	print("-- mint on first ensure --")
	test_ensure_mints_when_empty()

	print("\n-- ensure is idempotent --")
	test_ensure_idempotent()

	print("\n-- identity survives a restart (scratch round-trip) --")
	test_restart_restores_id_and_seq()

	print("\n-- start_new_implicit mints fresh + zeroes seq --")
	test_start_new_implicit()

	print("\n-- reconcile_floor never reuses a number --")
	test_reconcile_floor()

	print("\n-- adopt from loaded project_data --")
	test_adopt_existing_identity()
	test_adopt_legacy_mints()
	test_adopt_clears_scratch()

	print("\n-- write_to_project_data uses the canonical keys --")
	test_write_to_project_data()

	_clean_tmp()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ─────────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ── Fixtures ──────────────────────────────────────────────────────────────────

## Deterministic, monotonic UUID provider: "uuid-1", "uuid-2", ... The captured
## Array makes the count mutate across calls (Array is by-reference).
func _make_provider() -> Callable:
	var counter := [0]
	return func() -> String:
		counter[0] += 1
		return "uuid-%d" % counter[0]


func _path(name: String) -> String:
	return "%s_%s.cfg" % [TMP_DIR, name]


func _clean_tmp() -> void:
	# Remove any temp config files left from a prior run.
	for name in ["mint", "idem", "restart", "newimpl", "adopt", "adopt2", "adopt3"]:
		var p := _path(name)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_ensure_mints_when_empty() -> void:
	print("test_ensure_mints_when_empty:")
	var pid := ProjectIdentity.new(ConfigFile.new(), _path("mint"), _make_provider())
	pid.ensure()
	check_eq("mints the first id from the provider", pid.project_id, "uuid-1")
	check_eq("ref seq starts at 0", pid.annotation_ref_seq, 0)


func test_ensure_idempotent() -> void:
	print("test_ensure_idempotent:")
	var pid := ProjectIdentity.new(ConfigFile.new(), _path("idem"), _make_provider())
	pid.ensure()
	var first := pid.project_id
	pid.ensure()  # second call must not re-mint (provider would yield uuid-2)
	check_eq("second ensure() leaves id unchanged", pid.project_id, first)


func test_restart_restores_id_and_seq() -> void:
	print("test_restart_restores_id_and_seq:")
	var p := _path("restart")
	# Session A: mint, advance the counter, persist.
	var a := ProjectIdentity.new(ConfigFile.new(), p, _make_provider())
	a.ensure()
	a.reconcile_floor(5)       # seq -> 5
	a.persist_scratch()
	check_eq("session A id", a.project_id, "uuid-1")
	check_eq("session A seq", a.annotation_ref_seq, 5)

	# Session B = a restart: a brand-new ConfigFile loads the same scratch path.
	# A fresh provider would yield "uuid-1" too, so use one that starts elsewhere
	# to prove we RESTORE (not re-mint).
	var fresh_counter := [100]
	var other_provider := func() -> String:
		fresh_counter[0] += 1
		return "uuid-%d" % fresh_counter[0]
	var cfg_b := ConfigFile.new()
	cfg_b.load(p)
	var b := ProjectIdentity.new(cfg_b, p, other_provider)
	b.ensure()
	check_eq("restart restores the same id (no re-mint)", b.project_id, "uuid-1")
	check_eq("restart restores the seq", b.annotation_ref_seq, 5)


func test_start_new_implicit() -> void:
	print("test_start_new_implicit:")
	var pid := ProjectIdentity.new(ConfigFile.new(), _path("newimpl"), _make_provider())
	pid.ensure()              # uuid-1
	pid.reconcile_floor(9)    # seq -> 9
	pid.start_new_implicit()  # File -> New
	check_eq("new implicit mints a fresh id", pid.project_id, "uuid-2")
	check_eq("new implicit zeroes the ref seq", pid.annotation_ref_seq, 0)


func test_reconcile_floor() -> void:
	print("test_reconcile_floor:")
	var pid := ProjectIdentity.new(ConfigFile.new(), _path("idem"), _make_provider())
	pid.ensure()
	pid.annotation_ref_seq = 7
	check_eq("lower highest-seen leaves counter (returns 7)", pid.reconcile_floor(3), 7)
	check_eq("counter unchanged after lower floor", pid.annotation_ref_seq, 7)
	check_eq("higher highest-seen lifts counter (returns 12)", pid.reconcile_floor(12), 12)
	check_eq("counter raised to floor", pid.annotation_ref_seq, 12)


func test_adopt_existing_identity() -> void:
	print("test_adopt_existing_identity:")
	var pid := ProjectIdentity.new(ConfigFile.new(), _path("adopt"), _make_provider())
	pid.adopt_from_project_data({"project_id": "loaded-xyz", "annotation_ref_seq": 42})
	check_eq("adopts the loaded project_id", pid.project_id, "loaded-xyz")
	check_eq("adopts the loaded ref seq", pid.annotation_ref_seq, 42)


func test_adopt_legacy_mints() -> void:
	print("test_adopt_legacy_mints:")
	var pid := ProjectIdentity.new(ConfigFile.new(), _path("adopt2"), _make_provider())
	pid.adopt_from_project_data({})  # pre-P1 project with no identity
	check_eq("legacy project mints an id", pid.project_id, "uuid-1")
	check_eq("legacy ref seq defaults to 0", pid.annotation_ref_seq, 0)


func test_adopt_clears_scratch() -> void:
	print("test_adopt_clears_scratch:")
	var p := _path("adopt3")
	var cfg := ConfigFile.new()
	var pid := ProjectIdentity.new(cfg, p, _make_provider())
	pid.ensure()            # mints + persists scratch
	pid.persist_scratch()
	check("scratch present before adopt", cfg.has_section(ProjectIdentity.SCRATCH_SECTION))
	pid.adopt_from_project_data({"project_id": "explicit-1", "annotation_ref_seq": 3})
	check("scratch cleared after adopting an explicit project", not cfg.has_section(ProjectIdentity.SCRATCH_SECTION))


func test_write_to_project_data() -> void:
	print("test_write_to_project_data:")
	var pid := ProjectIdentity.new(ConfigFile.new(), _path("mint"), _make_provider())
	pid.ensure()
	pid.annotation_ref_seq = 11
	var data: Dictionary = {}
	pid.write_to_project_data(data)
	check_eq("writes project_id under the canonical key", data.get(ProjectIdentity.KEY_PROJECT_ID), pid.project_id)
	check_eq("writes ref seq under the canonical key", data.get(ProjectIdentity.KEY_REF_SEQ), 11)
	# Round-trips back through adopt (the read side) using the same keys.
	var pid2 := ProjectIdentity.new(ConfigFile.new(), _path("mint"), _make_provider())
	pid2.adopt_from_project_data(data)
	check_eq("adopt reads back the written id", pid2.project_id, pid.project_id)
	check_eq("adopt reads back the written seq", pid2.annotation_ref_seq, 11)
