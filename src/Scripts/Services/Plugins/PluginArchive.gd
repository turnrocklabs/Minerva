extends RefCounted
## Unpacks and checks a downloaded plugin archive for MarketplaceClient.
##
## unpack() works on a worker thread while the main thread keeps drawing
## frames: it reads the archive's headers first (PluginArchiveScan: unsafe
## names or links, expanded size, free disk space), then extracts with `tar`
## and verifies SHA256SUMS. Cancelling the operation stops the scan, kills
## tar, or stops hashing at the next chunk. check_identity() compares the
## archive's manifest with the registry entry it was chosen from and its
## entrypoint binary with this machine.
##
## Results use MarketplaceClient's shape: {ok:true} or {ok:false, error, detail}.

const Operation := preload("res://Scripts/Services/Plugins/PluginInstallOperation.gd")
const Scan := preload("res://Scripts/Services/Plugins/PluginArchiveScan.gd")

# tar has no progress to watch, so only a wedged process should hit this.
const TAR_TIMEOUT_S := 3600
const HASH_CHUNK := 1024 * 1024
# The largest published package (CAD, with its embedded Python and OCCT) is
# about 0.3 GiB compressed and expands to roughly three times that; 4 GiB
# leaves room for growth while stopping an archive that would fill a disk.
const MAX_EXPANDED_BYTES := 4 * 1024 * 1024 * 1024
# Free space kept beyond the expanded size, so an install never leaves the
# disk completely full.
const DISK_MARGIN_BYTES := 256 * 1024 * 1024

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
	var scan := Scan.new()
	var scanned := scan.scan(archive_abs, MAX_EXPANDED_BYTES, op)
	if not scanned.ok:
		outcome.merge(scanned)
		return
	var dest := DirAccess.open(dest_abs)
	var free := dest.get_space_left() if dest != null else 0
	if free < scan.total_bytes + DISK_MARGIN_BYTES:
		outcome.merge(_err("insufficient_disk_space", {"needed": scan.total_bytes + DISK_MARGIN_BYTES, "free": free}))
		return
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
	var listed := _listed_files(dir_abs)
	if not listed.ok:
		return listed
	var entries: Array[PackedStringArray] = listed.entries
	var total := 0
	for entry in entries:
		total += FileAccess.get_size(entry[2])
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


## The files `dir_abs`/SHA256SUMS lists, as [hex, relative path, absolute
## path] entries, each checked to be inside `dir_abs` and present; or the
## first problem, as an error result.
static func _listed_files(dir_abs: String) -> Dictionary:
	var sums_path := dir_abs.path_join("SHA256SUMS")
	if not FileAccess.file_exists(sums_path):
		return _err("missing_sha256sums", {"extract_dir": dir_abs})
	var entries: Array[PackedStringArray] = []
	for raw_line in FileAccess.get_file_as_string(sums_path).split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty():
			continue
		var parts := line.split("  ", false, 1)
		if parts.size() != 2:
			parts = line.split(" *", false, 1)
		if parts.size() != 2:
			return _err("sha256_mismatch", {"reason": "unparseable_line", "line": line})
		var relative := parts[1].strip_edges()
		if not Scan._contained(relative):
			return _err("sha256_mismatch", {"reason": "path_outside_archive", "file": relative})
		var file_path := dir_abs.path_join(relative)
		if not FileAccess.file_exists(file_path):
			return _err("sha256_mismatch", {"reason": "missing_file", "file": relative})
		entries.append(PackedStringArray([parts[0].strip_edges().to_lower(), relative, file_path]))
	if entries.is_empty():
		return _err("sha256_mismatch", {"reason": "empty_sums_file"})
	return {"ok": true, "entries": entries}


## Why the installed release in `dir_abs` cannot run here, or "" when it can:
## a file its SHA256SUMS lists is gone (checked only with `every_file`; a
## bundled runtime lists thousands), its "./" `entrypoint` is gone, or that
## entrypoint is a native executable built for none of `targets`. Existence
## and headers only, no hashing.
static func installed_issue(dir_abs: String, entrypoint: String, targets: Array[String],
		every_file: bool = true) -> String:
	if not every_file and not FileAccess.file_exists(dir_abs.path_join("SHA256SUMS")):
		return "its installed files are incomplete (SHA256SUMS)"
	var listed := _listed_files(dir_abs) if every_file else {"ok": true}
	if not listed.ok:
		var detail: Dictionary = listed.get("detail", {})
		return "its installed files are incomplete (%s)" % str(detail.get("file", detail.get("reason", "SHA256SUMS")))
	if not entrypoint.begins_with("./"):
		return ""
	var path := dir_abs.path_join(entrypoint.substr(2))
	if not FileAccess.file_exists(path) and FileAccess.file_exists(path + ".exe"):
		path += ".exe"
	if not FileAccess.file_exists(path):
		return "its entrypoint %s is missing" % entrypoint
	var built_for := _binary_target(path)
	if built_for.is_empty() or built_for in targets:
		return ""
	return "it is built for %s, not this computer (%s)" % [built_for, ", ".join(targets)]


## Compare the archive's manifest with `expected` (the registry entry's id
## and version; either may be absent for a direct URL install) and with
## `targets` (this machine's registry targets, MarketplaceClient.platform_targets;
## a universal macOS build runs on either Mac architecture). Archives carry no
## platform marker, and release_targets names every target a plugin supports,
## so the evidence is the packaged "./" entrypoint's executable header, which
## must name one of `targets`. An entrypoint that is not a native executable (a script,
## or a launcher named without "./") cannot be checked: the install goes
## ahead with platform_verified false. Returns {ok:true, platform_verified}
## or an identity_mismatch.
static func check_identity(manifest: Dictionary, expected: Dictionary, targets: Array[String], dir_abs: String) -> Dictionary:
	for field in ["id", "version"]:
		if expected.has(field) and str(manifest.get(field, "")) != str(expected[field]):
			return _mismatch(field, expected[field], manifest.get(field, ""))
	var target: String = targets[0] if not targets.is_empty() else ""
	var declared = manifest.get("release_targets", [])
	if declared is Array and not declared.is_empty() and not targets.any(func(t) -> bool: return t in declared):
		return _mismatch("platform", target, declared)
	var entrypoint := str((manifest.get("backend", {}) as Dictionary).get("entrypoint", ""))
	if not entrypoint.begins_with("./"):
		return {"ok": true, "platform_verified": false}
	if not Scan._contained(entrypoint.substr(2)):
		return _mismatch("entrypoint", "a path inside the plugin", entrypoint)
	var path := dir_abs.path_join(entrypoint.substr(2))
	if not FileAccess.file_exists(path) and FileAccess.file_exists(path + ".exe"):
		path += ".exe"
	if not FileAccess.file_exists(path):
		return _mismatch("platform", target, "no entrypoint binary " + entrypoint)
	var built_for := _binary_target(path)
	if built_for == "unreadable":
		return _mismatch("platform", target, "unreadable entrypoint " + entrypoint)
	if built_for.is_empty():
		return {"ok": true, "platform_verified": false}
	if not built_for in targets:
		return _mismatch("platform", target, built_for)
	return {"ok": true, "platform_verified": true}


## The registry target an executable runs as, from its header:
##   ELF, 64-bit little-endian, x86-64 / AArch64 -> linux-x86_64 / linux-arm64;
##   Mach-O universal ("fat") holding both x86_64 and arm64 -> macos-universal;
##   Mach-O single-architecture x86_64 / arm64  -> macos-amd64 / macos-arm64;
##   PE with a COFF machine of x86-64            -> windows-x86_64.
## Any other native binary is named by its format and machine (never a
## target), "unreadable" when the file cannot be read, and "" when it is not
## a native executable at all.
static func _binary_target(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "unreadable"
	var head := f.get_buffer(4096)
	if head.size() >= 20 and head.slice(0, 4) == PackedByteArray([0x7F, 0x45, 0x4C, 0x46]):
		var machine := head.decode_u16(18)
		if head[4] != 2 or head[5] != 1:
			return "elf (not 64-bit little-endian)"
		return {0x3E: "linux-x86_64", 0xB7: "linux-arm64"}.get(machine, "elf machine 0x%x" % machine)
	if head.size() >= 8 and _u32be(head, 0) in [0xCAFEBABE, 0xCAFEBABF]:
		# Fat header: big-endian count, then per-slice records whose first
		# field is the CPU type (20 bytes each; 32 for the 64-bit variant).
		var stride := 20 if _u32be(head, 0) == 0xCAFEBABE else 32
		var cpus := []
		for i in mini(_u32be(head, 4), 16):
			if 8 + i * stride + 4 <= head.size():
				cpus.append(_u32be(head, 8 + i * stride))
		if 0x01000007 in cpus and 0x0100000C in cpus:
			return "macos-universal"
		return "macos fat binary without both x86_64 and arm64"
	if head.size() >= 8 and head.decode_u32(0) in [0xFEEDFACF, 0xFEEDFACE]:
		return {0x01000007: "macos-amd64", 0x0100000C: "macos-arm64"}.get(
			head.decode_u32(4), "macos single-architecture binary")
	if head.size() >= 0x40 and head[0] == 0x4D and head[1] == 0x5A:
		var pe := head.decode_u32(0x3C)
		if pe + 6 > head.size():
			f.seek(pe)
			head = f.get_buffer(6)
			pe = 0
		if head.size() >= pe + 6 and head.slice(pe, pe + 4) == PackedByteArray([0x50, 0x45, 0, 0]):
			var machine := head.decode_u16(pe + 4)
			return "windows-x86_64" if machine == 0x8664 else "windows machine 0x%x" % machine
		return "windows (no PE header)"
	return ""


static func _u32be(bytes: PackedByteArray, at: int) -> int:
	return (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]


static func _mismatch(field: String, wanted, got) -> Dictionary:
	return _err("identity_mismatch", {"field": field, "expected": wanted, "actual": got})


static func _err(code: String, detail: Dictionary) -> Dictionary:
	return {"ok": false, "error": code, "detail": detail}
