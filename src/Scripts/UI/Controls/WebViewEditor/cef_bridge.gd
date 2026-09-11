class_name CefBridge
extends RefCounted
## CEF and WRY share the same bounded bridge; only the native send primitive differs.

static var BRIDGE_JS: String = MinervaBridge.BRIDGE_JS.replace("window.ipc.postMessage", "window.sendIpcMessage")
