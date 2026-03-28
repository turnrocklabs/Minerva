class_name MinervaBridge
extends RefCounted
## Holds the JavaScript bridge code that gets injected into webview panels.

const BRIDGE_JS: String = """
<script>
(function() {
	// Minerva Bridge -- allows webview panels to call MCP tools
	window.minerva = {
		_port: 9315,

		// Call any MCP tool: minerva.call('minerva_get_spreadsheet_data', {editor_name: 'My Sheet'})
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
			// MCP wraps result in content[0].text as JSON string
			const text = json.result?.content?.[0]?.text;
			return text ? JSON.parse(text) : json.result;
		},

		// Convenience: get spreadsheet data
		getSpreadsheet: function(name) {
			return this.call('minerva_get_spreadsheet_data', { editor_name: name });
		},

		// Convenience: update spreadsheet
		updateSpreadsheet: function(name, updates) {
			return this.call('minerva_update_spreadsheet_data', { editor_name: name, updates: updates });
		},

		// Convenience: create a note
		createNote: function(title, content, thread) {
			return this.call('minerva_create_note', { title: title, content: content, thread_name: thread || 'default' });
		},

		// Plugin IPC -- sends message through WRY ipc_message signal to Minerva broker
		pluginIPC: function(messageType, payload) {
			return new Promise(function(resolve, reject) {
				var id = '' + Date.now() + Math.random();
				window._minervaIPCPending = window._minervaIPCPending || {};
				window._minervaIPCPending[id] = { resolve: resolve, reject: reject };
				window.ipc.postMessage(JSON.stringify({
					id: id,
					type: messageType,
					payload: payload || {}
				}));
			});
		},

		// Register handler for plugin events pushed from Minerva
		onPluginEvent: function(callback) {
			window._minervaPluginEventHandlers = window._minervaPluginEventHandlers || [];
			window._minervaPluginEventHandlers.push(callback);
		},

		// Register handler for plugin state pushed from Minerva
		onPluginState: function(callback) {
			window._minervaPluginStateHandlers = window._minervaPluginStateHandlers || [];
			window._minervaPluginStateHandlers.push(callback);
		},

		// Called by Minerva (evaluate_javascript) to deliver IPC response
		_ipcReply: function(result) {
			var pending = (window._minervaIPCPending || {})[result.id];
			if (!pending) return;
			delete window._minervaIPCPending[result.id];
			if (result.success) pending.resolve(result.result);
			else pending.reject(new Error(result.error_message || 'IPC error'));
		},

		// Called by Minerva (evaluate_javascript) to push plugin event
		_dispatchPluginEvent: function(eventName, payload) {
			var handlers = window._minervaPluginEventHandlers || [];
			for (var i = 0; i < handlers.length; i++) {
				try { handlers[i](eventName, payload); } catch(e) { console.error('Plugin event handler error:', e); }
			}
		},

		// Called by Minerva (evaluate_javascript) to push plugin state
		_dispatchPluginState: function(state) {
			var handlers = window._minervaPluginStateHandlers || [];
			for (var i = 0; i < handlers.length; i++) {
				try { handlers[i](state); } catch(e) { console.error('Plugin state handler error:', e); }
			}
		}
	};

	console.log('[Minerva Bridge] Loaded -- window.minerva.call() / pluginIPC() available');
})();
</script>
"""
