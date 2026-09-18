class_name MinervaBridge
extends RefCounted
## Holds the JavaScript bridge code that gets injected into webview panels.

const BRIDGE_JS: String = """
<script>
(function() {
	// Every script and same-origin descendant in this host-created document is
	// one trusted principal. Navigation is locked natively for its lifetime.
	const CONTROL_BYTES = 65536;
	const CAPABILITY = '__MINERVA_DOCUMENT_CAPABILITY__';
	const sendNative = window.sendIpcMessage.bind(window);
	const pending = new Map();
	const MAX_PENDING = 128;
	const TIMEOUT_MS = 15000;
	function encodeBounded(value) {
		const encoded = JSON.stringify(value);
		if (new TextEncoder().encode(encoded).length > CONTROL_BYTES) {
			throw new Error('payload_too_large: control messages are limited to 65536 UTF-8 bytes; use the scene bulk route for documents');
		}
		return encoded;
	}
	function request(type, payload) {
		if (pending.size >= MAX_PENDING) return Promise.reject(new Error('too_many_pending_calls'));
		const id = crypto.randomUUID ? crypto.randomUUID() : '' + Date.now() + Math.random();
		let encoded;
		try {
			encoded = encodeBounded({capability: CAPABILITY, id, type, payload: payload || {}});
		} catch (error) {
			return Promise.reject(error);
		}
		return new Promise(function(resolve, reject) {
			const timer = setTimeout(function() {
				pending.delete(id); reject(new Error('bridge_timeout'));
			}, TIMEOUT_MS);
			pending.set(id, {resolve, reject, timer});
			try { sendNative(encoded); }
			catch (error) { pending.delete(id); clearTimeout(timer); reject(error); }
		});
	}
	// Minerva Bridge -- allows webview panels to call MCP tools
	window.minerva = {
		// Call any MCP tool: minerva.call('minerva_get_spreadsheet_data', {editor_name: 'My Sheet'})
		call: function(toolName, args) {
			return request('minerva.call', {tool: toolName, arguments: args || {}});
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

		// Plugin IPC -- sends through the native CEF bridge to the Minerva broker
		pluginIPC: async function(messageType, payload) {
			encodeBounded(payload || {});
			if (new TextEncoder().encode(messageType).length > 1024) throw new Error('IPC message type too long');
			return request(messageType, payload || {});
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
			var item = pending.get(result.id);
			if (!item) return;
			pending.delete(result.id); clearTimeout(item.timer);
			if (result.success) item.resolve(result.result);
			else item.reject(new Error(result.error_message || result.error || 'IPC error'));
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
