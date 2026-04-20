class_name CefBridge
extends RefCounted
## JavaScript bridge injected into CEF-hosted plugin panels.
##
## Differences from MinervaBridge (WRY-targeted):
##   - pluginIPC() uses window.sendIpcMessage(jsonString) instead of
##     window.ipc.postMessage. CEF's sendIpcMessage fires the CefTexture's
##     ipc_message(String) signal on the Godot side.
##   - Otherwise keeps the same window.minerva surface (call, pluginIPC,
##     onPluginEvent, onPluginState, _ipcReply, _dispatchPluginEvent,
##     _dispatchPluginState) so existing plugin panel HTML works unchanged.

const BRIDGE_JS: String = """
<script>
(function() {
	window.minerva = {
		_port: 9315,

		call: async function(toolName, args) {
			const payload = {
				jsonrpc: '2.0',
				id: Date.now(),
				method: 'tools/call',
				params: { name: toolName, arguments: args || {} }
			};
			const resp = await fetch('http://localhost:' + this._port, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(payload)
			});
			const json = await resp.json();
			if (json.error) throw new Error(json.error.message);
			const text = json.result?.content?.[0]?.text;
			return text ? JSON.parse(text) : json.result;
		},

		getSpreadsheet: function(name) {
			return this.call('minerva_get_spreadsheet_data', { editor_name: name });
		},
		updateSpreadsheet: function(name, updates) {
			return this.call('minerva_update_spreadsheet_data', { editor_name: name, updates: updates });
		},
		createNote: function(title, content, thread) {
			return this.call('minerva_create_note', { title: title, content: content, thread_name: thread || 'default' });
		},

		pluginIPC: function(messageType, payload) {
			return new Promise(function(resolve, reject) {
				var id = '' + Date.now() + Math.random();
				window._minervaIPCPending = window._minervaIPCPending || {};
				window._minervaIPCPending[id] = { resolve: resolve, reject: reject };
				var msg = JSON.stringify({
					id: id,
					type: messageType,
					payload: payload || {}
				});
				// CEF: sendIpcMessage with a JSON string fires ipc_message(String) on Godot.
				window.sendIpcMessage(msg);
			});
		},

		onPluginEvent: function(callback) {
			window._minervaPluginEventHandlers = window._minervaPluginEventHandlers || [];
			window._minervaPluginEventHandlers.push(callback);
		},
		onPluginState: function(callback) {
			window._minervaPluginStateHandlers = window._minervaPluginStateHandlers || [];
			window._minervaPluginStateHandlers.push(callback);
		},

		_ipcReply: function(result) {
			var pending = (window._minervaIPCPending || {})[result.id];
			if (!pending) return;
			delete window._minervaIPCPending[result.id];
			if (result.success) pending.resolve(result.result);
			else pending.reject(new Error(result.error_message || 'IPC error'));
		},
		_dispatchPluginEvent: function(eventName, payload) {
			var handlers = window._minervaPluginEventHandlers || [];
			for (var i = 0; i < handlers.length; i++) {
				try { handlers[i](eventName, payload); } catch(e) { console.error('Plugin event handler error:', e); }
			}
		},
		_dispatchPluginState: function(state) {
			var handlers = window._minervaPluginStateHandlers || [];
			for (var i = 0; i < handlers.length; i++) {
				try { handlers[i](state); } catch(e) { console.error('Plugin state handler error:', e); }
			}
		}
	};

	console.log('[Minerva Bridge/CEF] Loaded -- window.minerva.call() / pluginIPC() available');
})();
</script>
"""
