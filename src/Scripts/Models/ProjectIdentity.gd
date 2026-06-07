class_name ProjectIdentity
extends RefCounted
## Stable per-project identity for citeable annotation refs (DCR 019e9f602391, P1).
##
## Owns the project's `project_id` (a UUID) and `annotation_ref_seq` (the monotonic
## C<n> counter, vended in P2). Minerva has no project identity otherwise: projects
## are tracked name->path in config and `project_data` is a free-form dict zipped
## into the .minproj. This class supplies the missing stable handle so a comment
## minted as "C7" stays "C7" across Save / Save As / move / restart.
##
## Lifecycle:
##   - implicit (unsaved) session  -> identity persisted to a user:// scratch
##     (config section) so refs survive a restart before the first Save.
##   - explicit project (.minproj) -> identity lives in project_data; the scratch
##     is cleared on Save. Keyed on the UUID (not the path), so promotion to a
##     file, Save As, or rename never renumbers existing refs.
##
## SingletonObject holds one instance and delegates. The ConfigFile, its path, and
## the UUID provider are injected so this is unit-testable without the autoload or
## the scene tree. In production the SHARED SingletonObject.config_file instance is
## injected (so saves stay consistent with the rest of config); the UUID provider
## is SingletonObject.generate_UUID (DRY — one generator).

const SCRATCH_SECTION := "ImplicitProject"
const KEY_PROJECT_ID := "project_id"
const KEY_REF_SEQ := "annotation_ref_seq"

var project_id: String = ""
var annotation_ref_seq: int = 0

# True while this is the in-memory implicit (never-saved) project. Implicit
# projects keep their id/seq in the user:// scratch (crash-safe); explicit
# projects keep them in the .minproj and don't re-persist the scratch on vend.
var is_implicit: bool = true

# Test-only override for current(): lets MCP/host code reach a ProjectIdentity in
# a headless --script run where the SingletonObject autoload is not a resolved
# global. Production leaves this null and resolves via the autoload.
static var _override: ProjectIdentity = null

# Injected dependencies. The caller is responsible for having loaded `_config`
# from disk before `ensure()` (SingletonObject loads it in _ready); this class
# never reloads the shared instance, which would clobber other unsaved sections.
var _config: ConfigFile
var _config_path: String
var _uuid_provider: Callable


func _init(config: ConfigFile = null, config_path: String = "user://config_file.cfg", uuid_provider: Callable = Callable()) -> void:
	_config = config if config != null else ConfigFile.new()
	_config_path = config_path
	_uuid_provider = uuid_provider


## Restore the implicit session's identity from the user:// scratch, or mint a
## fresh one. Idempotent: a no-op once an identity is established in memory.
func ensure() -> void:
	if not project_id.is_empty():
		return
	if _config.has_section_key(SCRATCH_SECTION, KEY_PROJECT_ID):
		project_id = str(_config.get_value(SCRATCH_SECTION, KEY_PROJECT_ID, ""))
		annotation_ref_seq = int(_config.get_value(SCRATCH_SECTION, KEY_REF_SEQ, 0))
	if project_id.is_empty():
		_mint_fresh()


## Begin a brand-new implicit project (File -> New): fresh id + zeroed counter,
## written to the scratch so it survives a restart before the first Save.
func start_new_implicit() -> void:
	_mint_fresh()


## Adopt identity from a loaded .minproj's project_data. Legacy projects (pre-P1)
## carry no project_id -> mint one so identity is always present. The loaded
## project is now the explicit context: clear the implicit scratch and stop
## treating this as implicit.
func adopt_from_project_data(data: Dictionary) -> void:
	var loaded := str(data.get(KEY_PROJECT_ID, ""))
	project_id = loaded if not loaded.is_empty() else _mint_uuid()
	annotation_ref_seq = int(data.get(KEY_REF_SEQ, 0))
	is_implicit = false
	clear_scratch()


## Promote the implicit project to explicit (on Save): identity now lives in the
## .minproj, so drop the scratch and stop re-persisting it on vend.
func mark_explicit() -> void:
	is_implicit = false
	clear_scratch()


## Vend the next citeable ref ("C<n>") for this project and advance the counter.
## Never reuses a number. Persists the scratch only while implicit (explicit
## projects persist the seq into the .minproj on Save; a crash between saves is
## recovered by reconcile-on-load).
func vend_ref() -> String:
	annotation_ref_seq += 1
	if is_implicit:
		persist_scratch()
	return AnnotationRef.format(annotation_ref_seq)


## Stamp a citeable ref + ref_project onto an annotation envelope if it has none.
## Idempotent: an annotation keeps its first ref.
func stamp(annotation: Dictionary) -> void:
	if str(annotation.get("ref", "")).is_empty():
		annotation["ref"] = vend_ref()
		annotation["ref_project"] = project_id


## Best-effort handle to the live project identity for code that can't assume the
## SingletonObject autoload is a resolved global (MCP handlers, annotation hosts,
## headless --script tests). Returns null when unavailable; callers then skip ref
## stamping rather than crash.
static func current() -> ProjectIdentity:
	if _override != null:
		return _override
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var so := tree.root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	return so.get("project_identity") as ProjectIdentity


## Stamp the current identity into a project_data dict for serialization into a
## .minproj. Single writer, so the persisted keys can never drift from the read
## side in adopt_from_project_data().
func write_to_project_data(data: Dictionary) -> void:
	data[KEY_PROJECT_ID] = project_id
	data[KEY_REF_SEQ] = annotation_ref_seq


## Reconcile-on-load floor: a ref number can never be reused. Lift the counter to
## the highest ref already minted for this project. P2 passes the max C<n> found
## across sidecars / live hosts; at P1 nothing has minted yet so callers pass 0.
## Returns the (possibly raised) counter.
func reconcile_floor(highest_existing_ref: int) -> int:
	if highest_existing_ref > annotation_ref_seq:
		annotation_ref_seq = highest_existing_ref
	return annotation_ref_seq


## Persist the implicit identity to the user:// scratch. Call whenever the
## implicit id/seq changes (mint, or P2 ref vend on an unsaved project).
func persist_scratch() -> void:
	_config.set_value(SCRATCH_SECTION, KEY_PROJECT_ID, project_id)
	_config.set_value(SCRATCH_SECTION, KEY_REF_SEQ, annotation_ref_seq)
	_config.save(_config_path)


## Drop the implicit scratch — the project is now explicit (identity lives in the
## .minproj). Safe to call when no scratch exists.
func clear_scratch() -> void:
	if _config.has_section(SCRATCH_SECTION):
		_config.erase_section(SCRATCH_SECTION)
		_config.save(_config_path)


func _mint_fresh() -> void:
	project_id = _mint_uuid()
	annotation_ref_seq = 0
	is_implicit = true
	persist_scratch()


func _mint_uuid() -> String:
	if _uuid_provider.is_valid():
		return str(_uuid_provider.call())
	return _new_uuid()


## Fallback UUID generator, used when no provider is injected. Mirrors
## SingletonObject.generate_UUID() (sha256 of a random int) so this class has no
## hard dependency on the autoload; production injects generate_UUID directly.
static func _new_uuid() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return str(rng.randi()).sha256_text()
