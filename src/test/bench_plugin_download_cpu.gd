extends SceneTree
## One plugin-archive download, for scripts/bench-plugin-download-cpu.sh to
## time. User args: MODE URL DEST, where MODE is
##   httprequest — threaded HTTPRequest, as install_from_url downloaded before
##                 PluginDownloader;
##   downloader  — PluginDownloader.
## Exits 0 when DEST holds the whole body.

const DOWNLOADER_GD := "res://Scripts/Services/Plugins/PluginDownloader.gd"


func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var mode: String = args[0]
	var ok := false
	if mode == "httprequest":
		var http := HTTPRequest.new()
		http.use_threads = true
		http.download_file = args[2]
		root.add_child(http)
		http.request(args[1])
		var result: Array = await http.request_completed
		ok = result[0] == HTTPRequest.RESULT_SUCCESS and result[1] == 200
	else:
		var result: Dictionary = await load(DOWNLOADER_GD).new().download(args[1], args[2], self)
		ok = result.get("ok", false)
	quit(0 if ok else 1)
