class_name MediaArtifactKind
extends RefCounted
## Pure classifier for a generated media artifact, by filename extension
## (DCR 019ec7565d0f / O1). A media-gen result used to be assumed to be a PNG and
## force-loaded into the 2D graphics editor; with the 3d (GLB mesh) and movie
## (mp4 video) flavors the result can be a mesh or a video, which must route to a
## viewer instead. Dependency-free (no autoloads, no I/O) so it is unit-testable
## on its own — see test/test_media_artifact_kind.gd. The router lives in
## media_gen_manager.gd.

const IMAGE := &"image"
const VIDEO := &"video"
const MESH := &"mesh"
const OTHER := &"other"

## Lowercase, no dot.
const IMAGE_EXTENSIONS: Array[String] = [
	"png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "tiff", "tif",
]
const VIDEO_EXTENSIONS: Array[String] = [
	"mp4", "webm", "mov", "mkv", "avi", "m4v",
]
const MESH_EXTENSIONS: Array[String] = [
	"glb", "gltf", "obj", "stl", "ply", "fbx", "usd", "usdz", "usdc", "usda",
]


## Classify a filename (or path) into IMAGE / VIDEO / MESH / OTHER by extension.
static func classify(filename: String) -> StringName:
	var ext: String = filename.get_extension().to_lower()
	if ext in IMAGE_EXTENSIONS:
		return IMAGE
	if ext in VIDEO_EXTENSIONS:
		return VIDEO
	if ext in MESH_EXTENSIONS:
		return MESH
	return OTHER


## True for the artifact kinds the 2D graphics editor can display as a layer.
static func is_image(filename: String) -> bool:
	return classify(filename) == IMAGE
