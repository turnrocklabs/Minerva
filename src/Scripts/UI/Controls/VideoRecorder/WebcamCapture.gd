class_name WebcamCapture
extends RefCounted
## Wrapper around CameraServer for webcam capture.
## Provides graceful fallback when no camera is available.

var _feed: CameraFeed = null
var _feed_id: int = -1
var _active: bool = false
var _resolution: Vector2i = Vector2i(640, 480)
var _camera_texture: CameraTexture = null


## Ensure CameraServer is monitoring before querying feeds
static func _ensure_monitoring() -> void:
	if not CameraServer.is_monitoring_feeds():
		CameraServer.set_monitoring_feeds(true)


## Check if any camera is available
static func is_camera_available() -> bool:
	_ensure_monitoring()
	var feeds := CameraServer.feeds()
	return not feeds.is_empty()


## Get list of available camera names
static func get_camera_names() -> PackedStringArray:
	_ensure_monitoring()
	var names: PackedStringArray = []
	for feed in CameraServer.feeds():
		names.append(feed.get_name())
	return names


## Start capturing from the first available camera (or specified index)
func start(camera_index: int = 0) -> bool:
	_ensure_monitoring()
	var feeds := CameraServer.feeds()
	if feeds.is_empty():
		push_warning("[WebcamCapture] No cameras available")
		return false

	if camera_index >= feeds.size():
		camera_index = 0

	_feed = feeds[camera_index]
	_feed_id = _feed.get_id()

	if not _feed.is_active():
		# Linux requires setting a format before activating the feed
		var formats := _feed.get_formats()
		if not formats.is_empty():
			# Pick the first format that has a reasonable resolution
			var best_idx := 0
			for i in formats.size():
				var fmt: Dictionary = formats[i]
				var w: int = fmt.get("width", 0)
				var h: int = fmt.get("height", 0)
				if w >= 640 and h >= 480:
					best_idx = i
					break
			var chosen: Dictionary = formats[best_idx]
			_resolution = Vector2i(chosen.get("width", 640), chosen.get("height", 480))
			_feed.set_format(best_idx, chosen)
		_feed.set_active(true)

	# Create a persistent CameraTexture for frame retrieval (reused across get_frame calls)
	_camera_texture = CameraTexture.new()
	_camera_texture.camera_feed_id = _feed_id
	_camera_texture.which_feed = CameraServer.FEED_RGBA_IMAGE

	_active = true
	return true


## Stop capturing
func stop() -> void:
	if _feed and _feed.is_active():
		_feed.set_active(false)
	_feed = null
	_feed_id = -1
	_active = false
	_camera_texture = null


## Get the current webcam frame as an Image
func get_frame() -> Image:
	if not _active or not _camera_texture:
		return null
	var image := _camera_texture.get_image()
	if image and not image.is_empty():
		return image
	return null


## Get whether the camera is currently active
func is_active() -> bool:
	return _active and _feed != null


## Get the current feed resolution
func get_resolution() -> Vector2i:
	if not _feed:
		return Vector2i.ZERO
	return _resolution
