extends SceneTree
## Test: MediaArtifactKind — the pure classifier that routes a media-gen result
## (image / video / mesh) so non-image flavors (3d GLB, movie mp4) go to a viewer
## instead of the 2D graphics-editor layer (DCR 019ec7565d0f / O1).
## Run: godot --headless --path src --script test/test_media_artifact_kind.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== MediaArtifactKind Tests ===\n")
	test_images()
	test_videos()
	test_meshes()
	test_other_and_edgecases()
	test_is_image_helper()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func test_images() -> void:
	print("test_images")
	check("png -> image", MediaArtifactKind.classify("ComfyUI_0001.png") == MediaArtifactKind.IMAGE)
	check("PNG upper -> image", MediaArtifactKind.classify("out.PNG") == MediaArtifactKind.IMAGE)
	check("jpg -> image", MediaArtifactKind.classify("photo.jpg") == MediaArtifactKind.IMAGE)
	check("webp -> image", MediaArtifactKind.classify("a.webp") == MediaArtifactKind.IMAGE)


func test_videos() -> void:
	print("test_videos")
	check("mp4 -> video", MediaArtifactKind.classify("WanT2V_00001.mp4") == MediaArtifactKind.VIDEO)
	check("webm -> video", MediaArtifactKind.classify("clip.webm") == MediaArtifactKind.VIDEO)
	check("mov -> video", MediaArtifactKind.classify("a.MOV") == MediaArtifactKind.VIDEO)


func test_meshes() -> void:
	print("test_meshes")
	check("glb -> mesh", MediaArtifactKind.classify("Hunyuan3D_00001_.glb") == MediaArtifactKind.MESH)
	check("gltf -> mesh", MediaArtifactKind.classify("scene.gltf") == MediaArtifactKind.MESH)
	check("obj -> mesh", MediaArtifactKind.classify("model.obj") == MediaArtifactKind.MESH)
	check("stl -> mesh", MediaArtifactKind.classify("part.STL") == MediaArtifactKind.MESH)


func test_other_and_edgecases() -> void:
	print("test_other_and_edgecases")
	check("unknown ext -> other", MediaArtifactKind.classify("blob.xyz") == MediaArtifactKind.OTHER)
	check("no extension -> other", MediaArtifactKind.classify("Makefile") == MediaArtifactKind.OTHER)
	check("full path classified", MediaArtifactKind.classify("/a/b/c/out.glb") == MediaArtifactKind.MESH)


func test_is_image_helper() -> void:
	print("test_is_image_helper")
	check("png is_image true", MediaArtifactKind.is_image("x.png") == true)
	check("mp4 is_image false", MediaArtifactKind.is_image("x.mp4") == false)
	check("glb is_image false", MediaArtifactKind.is_image("x.glb") == false)
