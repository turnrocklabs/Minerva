class_name OSOpenPolicy
extends RefCounted
## Pure allowlist policy for minerva_os_open (W11). Dependency-free (no autoloads,
## no I/O) so it is unit-testable on its own, separate from the MCPOSTools handler
## that reads config + calls OS.shell_open.
##
## A path may be opened in the OS default app when its extension is a known-safe
## document/media type (DEFAULT_EXTENSIONS, extendable via config) OR its filename
## is in a user-approved named-binary allowlist (e.g. "Docket.app" — lets the user
## approve a specific executable/app by name without opening the floodgates).

## Safe-by-default document/media extensions (lowercase, no dot). Compiled in so a
## fresh binary install opens these with zero config present.
const DEFAULT_EXTENSIONS: Array[String] = [
	"pdf", "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg",
	"txt", "md", "csv", "tsv", "rtf", "log", "json",
	"html", "htm", "docx", "doc", "xlsx", "xls", "pptx", "ppt",
	"odt", "ods", "odp",
	# Generated-media artifacts (O1): movie (video) + 3d (mesh) flavors are
	# opened in the OS default viewer.
	"mp4", "webm", "mov", "mkv", "m4v",
	"glb", "gltf", "obj", "stl", "ply", "usdz",
]


## True when the path is allowed to open: filename in allowed_binaries
## (case-insensitive) OR extension in DEFAULT_EXTENSIONS / extra_extensions.
static func is_allowed(path: String, extra_extensions: PackedStringArray, allowed_binaries: PackedStringArray) -> bool:
	var base_lower: String = path.get_file().to_lower()
	for b in allowed_binaries:
		var bn: String = b.strip_edges().to_lower()
		if bn != "" and base_lower == bn:
			return true
	var ext: String = path.get_extension().to_lower()
	if ext == "":
		return false
	if ext in DEFAULT_EXTENSIONS:
		return true
	for e in extra_extensions:
		if e.strip_edges().to_lower().lstrip(".") == ext:
			return true
	return false
