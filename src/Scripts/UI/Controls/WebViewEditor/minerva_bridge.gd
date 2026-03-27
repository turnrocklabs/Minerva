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
		}
	};

	console.log('[Minerva Bridge] Loaded -- window.minerva.call() available');
})();
</script>
"""
