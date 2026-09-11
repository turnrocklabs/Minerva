// Run with Node; exercises the actual injected bridge with streaming Fetch bodies.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../Scripts/UI/Controls/WebViewEditor/minerva_bridge.gd'), 'utf8')
  .split('"""')[1].replace('<script>', '').replace('</script>', '');

(async () => {
  for (const cef of [false, true]) {
    let calls = 0, sends = 0;
    let response = JSON.stringify({result: {content: [{text: '{"ok":true}'}]}});
    const window = {ipc: {postMessage() { sends++; }}, sendIpcMessage() { sends++; }};
    const context = {window, TextEncoder, TextDecoder, Uint8Array, console,
      fetch: async (_, opts) => {
        calls++;
        assert.equal(opts.headers['X-Minerva-Control'], '1');
        return new Response(response);
      }};
    vm.runInNewContext(cef ? source.replaceAll('window.ipc.postMessage', 'window.sendIpcMessage') : source, context);
    const api = window.minerva;
    assert.equal((await api.call('minerva_probe', {})).ok, true);
    await assert.rejects(api.call('minerva_probe', {text: '🙂'.repeat(17000)}), /payload_too_large/);
    assert.equal(calls, 1, 'oversize requests never execute fetch');
    response = JSON.stringify({result: {content: [{text: '🙂'.repeat(17000)}]}});
    await assert.rejects(api.call('minerva_probe', {}), /payload_too_large/);
    assert.equal(calls, 2);
    await assert.rejects(api.pluginIPC('probe', {text: '🙂'.repeat(17000)}), /payload_too_large/);
    assert.equal(sends, 0, 'oversize plugin requests never send native IPC');
    assert.equal(Object.keys(window._minervaIPCPending || {}).length, 0, 'rejected requests do not leak pending promises');
    let failures = 0;
    api.onIPCError(() => failures++);
    api._dispatchIPCError({error_code: 'payload_too_large'});
    assert.equal(failures, 1, 'delivery failure is explicit, separate from state');
  }
  console.log('PASS: WRY and CEF direct calls, streamed replies, native IPC bounds and delivery errors');
})().catch(error => { console.error(error); process.exitCode = 1; });
