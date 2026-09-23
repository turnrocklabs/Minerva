extends RefCounted
## Unpacks and checks a downloaded plugin archive for MarketplaceClient.
##
## unpack() extracts with `tar` and verifies SHA256SUMS on a worker thread
## while the main thread keeps drawing frames. Cancelling the operation kills
## tar, or stops hashing at the next chunk. check_identity() compares the
## archive's manifest with the registry entry it was chosen from and with
## this machine.
##
## Results use MarketplaceClient's shape: {ok:true} or {ok:false, error, detail}.

const Operation := preload("res://Scripts/Services/Plugins/PluginInstallOperation.gd")

# tar has no progress to watch, so only a wedged process should hit this.
const TAR_TIMEOUT_S := 3600
const HASH_CHUNK := 1024 * 1024

# Written by the worker, read by the main thread for progress.
var _verify_total := -1
var _hashed := 0


## Extract `archive_abs` into the existing directory `dest_abs`, then verify
## every file listed in its SHA256SUMS. Moves `op` through the extract and
## verify stages.
func unpack(archive_abs: String, dest_abs: String, op: Operation, tree: SceneTree) -> Dictionary:
	op.enter(Operation.STAGE_EXTRACT)
	var outcome := {}
	var worker := Thread.new()
	worker.start(_work.bind(archive_abs, dest_abs, op, outcome))
	while worker.is_alive():
		if _verify_total >= 0:
			if op.stage != Operation.STAGE_VERIFY:
				op.enter(Operation.STAGE_VERIFY)
				op.total = _verify_total
			op.done = _hashed
		await tree.process_frame
	worker.wait_to_finish()
	return outcome


func _work(archive_abs: String, dest_abs: String, op: Operation, outcome: Dictionary) -> void:
	var argv: Array[String] = ["tar", "-xzf", archive_abs, "-C", dest_abs]
	var run := SetupExecutors.spawn(argv, TAR_TIMEOUT_S, func() -> bool: return op.cancelled)
	if run.stopped:
		outcome.merge(_err("cancelled", {}))
		return
	if run.exit_code != 0:
		outcome.merge(_err("extract_failed", {"rc": run.exit_code, "stderr": run.stderr}))
		return
	outcome.merge(_verify_sums(dest_abs, op))


## Every "<hex>  <file>" (or "<hex> *<file>") line of SHA256SUMS must match
## the extracted file. Sizes are summed first so progress has a total.
func _verify_sums(dir_abs: String, op: Operation) -> Dictionary:
	var sums_path := dir_abs.path_join("SHA256SUMS")
	if not FileAccess.file_exists(sums_path):
		return _err("missing_sha256sums", {"extract_dir": dir_abs})
	var entries: Array[PackedStringArray] = []
	var total := 0
	for raw_line in FileAccess.get_file_as_string(sums_path).split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty():
			continue
		var parts := line.split("  ", false, 1)
		if parts.size() != 2:
			parts = line.split(" *", false, 1)
		if parts.size() != 2:
			return _err("sha256_mismatch", {"reason": "unparseable_line", "line": line})
		var file_path := dir_abs.path_join(parts[1].strip_edges())
		if not FileAccess.file_exists(file_path):
			return _err("sha256_mismatch", {"reason": "missing_file", "file": parts[1].strip_edges()})
		total += FileAccess.get_size(file_path)
		entries.append(PackedStringArray([parts[0].strip_edges().to_lower(), parts[1].strip_edges(), file_path]))
	if entries.is_empty():
		return _err("sha256_mismatch", {"reason": "empty_sums_file"})
	_verify_total = total

	for entry in entries:
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		var f := FileAccess.open(entry[2], FileAccess.READ)
		if f == null:
			return _err("sha256_mismatch", {"reason": "unreadable_file", "file": entry[1]})
		while not f.eof_reached():
			if op.cancelled:
				return _err("cancelled", {})
			var chunk := f.get_buffer(HASH_CHUNK)
			if chunk.is_empty():
				break  # HashingContext rejects an empty update
			ctx.update(chunk)
			_hashed += chunk.size()
		var actual := ctx.finish().hex_encode()
		if actual != entry[0]:
			return _err("sha256_mismatch", {"reason": "hash_mismatch", "file": entry[1],
				"expected": entry[0], "actual": actual})
	return {"ok": true}


## Compare the archive's manifest with `expected` (the registry entry's id
## and version; either may be absent for a direct URL install) and with
## `target` (this machine's registry target). Archives carry no platform
## marker, so the platform evidence is the manifest's release_targets and
## the executable format of a packaged entrypoint. Returns {} when they agree.
static func check_identity(manifest: Dictionary, expected: Dictionary, target: String, dir_abs: String) -> Dictionary:
	for field in ["id", "version"]:
		if expected.has(field) and str(manifest.get(field, "")) != str(expected[field]):
			return _mismatch(field, expected[field], manifest.get(field, ""))
	var targets = manifest.get("release_targets", [])
	if targets is Array and not targets.is_empty() and not target in targets:
		return _mismatch("platform", target, targets)
	var entrypoint := str((manifest.get("backend", {}) as Dictionary).get("entrypoint", ""))
	if entrypoint.begins_with("./"):
		var path := dir_abs.path_join(entrypoint.substr(2))
		if not FileAccess.file_exists(path) and FileAccess.file_exists(path + ".exe"):
			path += ".exe"
		var built_for := _binary_platform(path)
		var wanted := target if target.begins_with("linux") else target.get_slice("-", 0)
		if not built_for.is_empty() and built_for != wanted:
			return _mismatch("platform", wanted, built_for)
	return {}


## "linux-x86_64", "linux-arm64", "linux-other", "macos", or "windows" from
## the file's executable header; "" when it is not a native executable (a
## script, a placeholder) or cannot be read.
static func _binary_platform(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var head := f.get_buffer(20)
	if head.size() >= 20 and head.slice(0, 4) == PackedByteArray([0x7F, 0x45, 0x4C, 0x46]):
		return {0x3E: "linux-x86_64", 0xB7: "linux-arm64"}.get(head.decode_u16(18), "linux-other")
	# Mach-O 64-bit and universal ("fat") magics, in either byte order.
	if head.size() >= 4 and head.decode_u32(0) in [0xFEEDFACF, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA]:
		return "macos"
	if head.size() >= 2 and head[0] == 0x4D and head[1] == 0x5A:
		return "windows"
	return ""


static func _mismatch(field: String, wanted, got) -> Dictionary:
	return _err("identity_mismatch", {"field": field, "expected": wanted, "actual": got})


static func _err(code: String, detail: Dictionary) -> Dictionary:
	return {"ok": false, "error": code, "detail": detail}
