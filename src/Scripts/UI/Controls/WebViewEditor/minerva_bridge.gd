class_name MinervaBridge
extends RefCounted
## Holds the JavaScript bridge code that gets injected into webview panels.

const BRIDGE_JS: String = """
<script>
(function() {
	const CONTROL_BYTES = 65536;
	function encodeBounded(value) {
		const encoded = JSON.stringify(value);
		if (new TextEncoder().encode(encoded).length > CONTROL_BYTES) {
			throw new Error('payload_too_large: control messages are limited to 65536 UTF-8 bytes; use the scene bulk route for documents');
		}
		return encoded;
	}
	async function readBoundedJSON(resp) {
		const reader = resp.body.getReader();
		const chunks = [];
		let size = 0;
		try {
			while (true) {
				const part = await reader.read();
				if (part.done) break;
				size += part.value.byteLength;
				if (size > CONTROL_BYTES) {
					await reader.cancel();
					throw new Error('payload_too_large: MCP response exceeds 65536 UTF-8 bytes');
				}
				chunks.push(part.value);
			}
		} finally { reader.releaseLock(); }
		const bytes = new Uint8Array(size);
		let offset = 0;
		for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
		return JSON.parse(new TextDecoder().decode(bytes));
	}
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
				headers: { 'Content-Type': 'application/json', 'X-Minerva-Control': '1' },
				body: encodeBounded(payload)
			});
			const json = await readBoundedJSON(resp);
			if (json.error) throw new Error(json.error.message);
			// MCP tool errors arrive as a resolved result with isError:true; throw
			// so callers see them in .catch() rather than silently swallowing.
			let data = json.result;
			if (data && data.isError === true) {
				const msg = data.content?.[0]?.text || 'MCP tool reported an error';
				throw new Error(msg);
			}
			// Success: unwrap content[0].text if it's a JSON string; otherwise
			// return it as-is (some tools return plain text content).
			const text = data?.content?.[0]?.text;
			if (typeof text === 'string') {
				try { return JSON.parse(text); } catch(e) { return text; }
			}
			return data;
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
				encodeBounded(payload || {});
				if (new TextEncoder().encode(messageType).length > 1024) throw new Error('IPC message type too long');
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

		onIPCError: function(callback) {
			window._minervaIPCErrorHandlers = window._minervaIPCErrorHandlers || [];
			window._minervaIPCErrorHandlers.push(callback);
		},
		_dispatchIPCError: function(error) {
			console.error('Minerva IPC delivery failed:', error);
			for (const callback of (window._minervaIPCErrorHandlers || [])) {
				try { callback(error); } catch (e) { console.error(e); }
			}
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
