// Run with Node; exercises the actual generation-capability native bridge.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const { webcrypto } = require('node:crypto');
const source = fs.readFileSync(path.join(__dirname, '../Scripts/UI/Controls/WebViewEditor/minerva_bridge.gd'), 'utf8')
  .split('"""')[1].replace('<script>', '').replace('</script>', '')
  .replaceAll('__MINERVA_DOCUMENT_CAPABILITY__', 'fixture-capability');

(async () => {
  for (const cef of [false, true]) {
    let sends = 0, api;
    const deliver = raw => {
      sends++;
      const message = JSON.parse(raw);
      assert.equal(message.capability, 'fixture-capability');
      queueMicrotask(() => api._ipcReply({id: message.id, success: true,
        result: {ok: true, type: message.type}}));
    };
    const window = {sendIpcMessage: deliver};
    if (!cef) window.ipc = {postMessage: deliver};
    const context = {window, TextEncoder, console, crypto: webcrypto,
      setTimeout, clearTimeout, queueMicrotask};
    vm.runInNewContext(source, context);
    api = window.minerva;
    assert.deepEqual(await api.call('minerva_probe', {}), {ok: true, type: 'minerva.call'});
    assert.deepEqual(await api.pluginIPC('probe', {}), {ok: true, type: 'probe'});
    await assert.rejects(api.call('minerva_probe', {text: '🙂'.repeat(17000)}), /payload_too_large/);
    await assert.rejects(api.pluginIPC('probe', {text: '🙂'.repeat(17000)}), /payload_too_large/);
    assert.equal(sends, 2, 'oversize requests never send native IPC');
    let failures = 0;
    api.onIPCError(() => failures++);
    api._dispatchIPCError({error_code: 'payload_too_large'});
    assert.equal(failures, 1, 'delivery failure is explicit, separate from state');
  }
  console.log('PASS: WRY and CEF native calls, capability framing, bounds and replies');
})().catch(error => { console.error(error); process.exitCode = 1; });
