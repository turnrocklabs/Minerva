"""The one live Context e2e (minerva:01a17459de19); run via run_context_compaction.py.

All external JSON is dynamic. Product code is untouched apart from registering
the test observer in this disposable job copy. No raw app output leaves tmpfs.
"""
from __future__ import annotations

import hashlib
import http.client
import json
import os
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

INPUTS = Path(__file__).resolve().parent
PRIVATE = Path('/tmp/live-context')
ASSETS = Path('/src/.live-context-assets')



def rpc(port: int, method: str, params: dict[str, Any], session: dict[str, str], request_id: int) -> dict[str, Any]:
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=45)
    headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', **session}
    request = {'jsonrpc': '2.0', 'id': request_id, 'method': method, 'params': params}
    try:
        connection.request('POST', '/mcp', json.dumps(request), headers)
        response = connection.getresponse()
        raw = response.read()
        if response.status != 200:
            raise RuntimeError('MCP HTTP status refused')
        for key in ('MCP-Session-Id', 'MCP-Protocol-Version'):
            if response.getheader(key):
                session[key] = response.getheader(key)
        data = json.loads(raw)
        if 'error' in data:
            raise RuntimeError('MCP RPC refused')
        result = data['result']
        if method == 'tools/call':
            blocks = result.get('content', [])
            result = json.loads(next(b['text'] for b in blocks if b.get('type') == 'text'))

        return result
    finally:
        connection.close()


def retire(process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()  # Only a Popen owned by this driver; never PID discovery.
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)


class GoalFailure(Exception):
    """An observed product assertion, distinct from harness/prerequisite failure."""


def read_json(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None  # The observer may be publishing this file; deadline bounds the wait.


def exercise(private: Path, app: subprocess.Popen, deadline: float) -> int:
    report: dict[str, Any] = {'status': 'running', 'turns': [], 'settings': {}, 'started_at': time.time()}
    sequence = 0
    session: dict[str, str] = {}

    def wait_file(name: str, wanted_sequence: int = 0) -> dict[str, Any]:
        while time.monotonic() < deadline:
            stopped = read_json(private / 'stop.json')
            if stopped is not None or app.poll() is not None:
                raise RuntimeError('Live prerequisite stopped')
            value = read_json(private / (name + '.json'))
            if value is not None and int(value.get('sequence', 0)) == wanted_sequence:
                return value
            time.sleep(.05)
        raise TimeoutError('Live e2e deadline')

    def observe(action: str, **arguments: str) -> dict[str, Any]:
        nonlocal sequence
        sequence += 1
        command = {'sequence': sequence, 'action': action, **arguments}
        pending = private / 'command.pending'
        pending.write_text(json.dumps(command))
        pending.replace(private / 'command.json')
        return wait_file('answer', sequence)['result']

    def check(condition: bool, assertion: str) -> None:
        if not condition:
            report['assertion'] = assertion
            raise GoalFailure(assertion)

    try:
        ready = wait_file('ready')
        report['advertised_max_output'] = ready['max_output']
        if float(ready['max_output'].get('maximum', 0)) < 4000 or not ready['async_advertised']:
            raise RuntimeError('GLM output/async precondition unavailable')
        port = int(ready['port'])
        rpc(port, 'initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                                'clientInfo': {'name': 'live-context-e2e', 'version': '1'}}, session, 1)
        call_id = 1

        def tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
            nonlocal call_id
            call_id += 1
            return rpc(port, 'tools/call', {'name': name, 'arguments': arguments}, session, call_id)

        created = tool('minerva_create_chat', {'name': 'Live Context acceptance', 'model_spec': ready['model_spec']})
        if not created.get('success'):
            raise RuntimeError('MCP create failed')
        chat_id = created['chat_id']
        bound = observe('bind', chat_id=chat_id)
        if not bound.get('bound') or not bound.get('async_supported'):
            raise RuntimeError('GUI chat/async binding failed')
        options = {'context_window': 65000, 'auto_compact_at': 6500, 'max_output_tokens': 4000, 'reasoning_effort': 'low'}
        report['settings']['requested'] = options
        report['settings']['attempted_at'] = time.time()
        saved = tool('minerva_set_generation_options', {'chat_id': chat_id, 'scope': 'model', 'options': options})
        if not saved.get('success'):
            code = str(saved.get('error_code', ''))
            report['settings']['error_code'] = code if code in ['unsupported_generation_option', 'invalid_generation_options', 'invalid_generation_option'] else 'unclassified'
            message = str(saved.get('error_message', saved.get('error', '')))
            missing = next((key for key in ('context_window', 'auto_compact_at') if key in message), None)
            report['settings']['rejected_setting'] = missing
            if missing is not None and report['settings']['error_code'] != 'unclassified':
                check(False, 'settings_rejected')
            raise RuntimeError('Settings refused for an unexpected reason')
        readback = tool('minerva_get_generation_options', {'chat_id': chat_id})
        check(readback.get('success') and all(readback.get('model_options', {}).get(k) == v for k, v in options.items()), 'mcp_settings_readback')
        dialog = observe('settings')
        report['settings']['dialog'] = dialog
        check(dialog.get('visible') and dialog.get('context_heading') and dialog.get('reasoning_low') and dialog.get('values') == {
            'Context window': 65000, 'Auto-compact at': 6500, 'Max output tokens (per turn)': 4000}, 'dialog_settings_readback')

        pending_eligible: int | None = None

        def turn(prompt: str, kind: str) -> dict[str, Any]:
            nonlocal pending_eligible
            before = observe('begin', prompt=prompt)
            record = {'kind': kind, 'prompt_chars': len(prompt), 'input_before': before['input_estimate'], 'output_reserve': 4000,
                      'budget_before': before['total_budget'], 'mcp_send_at': time.time()}
            report['turns'].append(record)
            turn_index = len(report['turns']) - 1
            if before['input_estimate'] >= 6500 and pending_eligible is None:
                pending_eligible = turn_index
            check(before['total_budget'] <= 65000, 'context_window_exceeded')
            prior_count = len(before['compactions'])
            sent = tool('minerva_send_message', {'chat_id': chat_id, 'message': prompt})
            if not sent.get('success') or sent.get('queued'):
                raise RuntimeError('Normal MCP send did not start')
            while time.monotonic() < deadline:
                after = observe('state')
                check(not after['large_context_dialog'], 'large_context_dialog')
                if after['complete']:
                    break
                time.sleep(.15)
            else:
                raise TimeoutError('Live turn deadline')
            fresh = after['compactions'][prior_count:]
            record.update({'times': after['times'], 'usage': after['usage'], 'reply': after['reply'],
                           'job_ids': after['job_ids'], 'compactions': fresh, 'finished_at': time.time()})
            check(not after['reply'].get('error') and len(after['job_ids']) == (2 if fresh else 1), 'async_turn_failed')
            check('prompt_tokens' in after['usage'] and 'completion_tokens' in after['usage'], 'server_usage_missing')
            check(after['usage']['completion_tokens'] <= 4000, 'output_limit_exceeded')
            input_used = fresh[-1]['input_after'] if fresh else before['input_estimate']
            record['input_used'] = input_used
            prompt_tokens = after['usage']['prompt_tokens']
            record['estimate_ratio'] = input_used / prompt_tokens if prompt_tokens else None
            record['accuracy_asserted'] = prompt_tokens >= 1000
            if prompt_tokens >= 1000:
                check(.7 <= record['estimate_ratio'] <= 1.3, 'input_estimate_accuracy')
            check(input_used + 4000 <= 65000 and prompt_tokens + 4000 <= 65000, 'context_window_exceeded')
            if fresh:
                check(before['input_estimate'] >= 6500 and pending_eligible == turn_index, 'compaction_threshold_timing')
                pending_eligible = None
            for compact in fresh:
                check(compact['input_after'] < 6500, 'compaction_did_not_reduce_input')
                check(compact['summary_present'] and compact['ledger_link_present'] and compact['ledger_exists'], 'summary_or_ledger_missing')
                check(compact['summarizer_glm'], 'summary_provider_not_glm')
            return record

        turn('hi', 'warmup')
        for index in range(15):
            prompt = ('Write the opening of an original adventure story, about 600 words.' if index == 0
                      else 'Continue the story, about 600 words.')
            story = turn(prompt, 'story')
            if story['compactions']:
                turn('Continue the story, about 600 words.', 'after_compaction')
                break
        else:
            check(False, 'compaction_missing_at_15_turn_cap')
        local = observe('local_safety')
        capture = wait_file('local-capture')
        report['local_ollama'] = {**local, 'sent_num_ctx': capture.get('num_ctx'), 'transport': 'real provider to owned loopback capture'}
        check(local['default_num_ctx'] == local['effective_num_ctx'] == capture.get('num_ctx') == 8192, 'local_num_ctx_changed')
        report['status'] = 'green'
        return 0
    except GoalFailure:
        report['status'] = 'red'
        return 1
    except (OSError, ValueError, KeyError, StopIteration, RuntimeError, http.client.HTTPException) as error:
        report.update({'status': 'harness_or_prerequisite_failure', 'failure_type': type(error).__name__})
        stopped = read_json(private / 'stop.json')
        if stopped is not None:
            report['prerequisite'] = stopped
        return 90
    finally:
        report['finished_at'] = time.time()
        Path('/out/report.json').write_text(json.dumps(report, indent=2) + '\n')


def run() -> int:
    repo = Path.cwd()
    PRIVATE.mkdir(mode=0o700)
    safe_env = {k: v for k, v in os.environ.items()
                if k not in ('MINERVA_TEST_USERNAME', 'MINERVA_TEST_PASSWORD')}
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], env=safe_env).decode().strip()
    assert os.environ.get('MINERVA_TEST_USERNAME') and os.environ.get('MINERVA_TEST_PASSWORD')
    pins = json.loads((INPUTS / 'pins.json').read_text())
    for pin in pins:
        assert hashlib.sha256((ASSETS / pin['asset']).read_bytes()).hexdigest() == pin['sha256']
    summary = {'revision': revision, 'attempt': 1,
               'gui': 'Xvfb', 'driver': 'HTTP MCP create/send', 'profile': 'owned exec tmpfs',
               'fixture_pins_sha256': hashlib.sha256((INPUTS / 'pins.json').read_bytes()).hexdigest()}
    app = display = None
    stage = 'native_setup'
    try:
        with (PRIVATE / 'setup.log').open('w') as setup:
            subprocess.run(['python3', '-B', 'scripts/container-build/dev-natives.py'],
                           stdout=setup, stderr=subprocess.STDOUT, env=safe_env, check=True)
            project = repo / 'src/project.godot'
            marker = 'WatcherRuntime="*res://Scripts/Services/Watcher/WatcherRuntime.gd"'
            original = project.read_text()
            assert original.count(marker) == 1
            project.write_text(original.replace(marker, marker + '\nLiveContextObserver="*res://test/live_context_compaction.gd"'))
            child_env = dict(os.environ)
            for key in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME'):
                directory = PRIVATE / key.lower()
                directory.mkdir()
                child_env[key] = str(directory)
            user = Path(child_env['XDG_DATA_HOME']) / 'godot/app_userdata/Minerva'
            user.mkdir(parents=True)
            (user / 'config_file.cfg').write_text('[Voice]\nturnrock_enabled=false\nalways_listening=false\n[HCP]\nauto_connect=false\n')
            disabled = [{'name': n, 'type': 'http', 'url': 'http://127.0.0.1:9',
                         'enabled': False, 'auto_connect': False, 'origin': 'known'} for n in ('nudge', 'cobrowser')]
            (user / 'mcp_config.json').write_text(json.dumps({'version': 3, 'servers': disabled}))
            docket = user.with_name('Docket')
            docket.mkdir()
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                (docket / 'docket_prefs.json').write_text(json.dumps({'mcp_port': probe.getsockname()[1]}))
            snapshot = json.loads((INPUTS / 'required-releases.json').read_text())

            class Handler(BaseHTTPRequestHandler):
                def do_GET(self) -> None:
                    path = urlsplit(self.path).path
                    if path.startswith('/assets/'):
                        target = ASSETS / Path(path).name
                        if not target.is_file():
                            self.send_error(404)
                            return
                        body = target.read_bytes()
                    elif path.startswith('/repos/') and path.endswith('/releases'):
                        name = path.removeprefix('/repos/').removesuffix('/releases')
                        body = json.dumps(snapshot.get(name, [[]])[0]).encode()
                    else:
                        self.send_error(404)
                        return
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

                def do_POST(self) -> None:
                    if urlsplit(self.path).path != '/v1/chat/completions':
                        self.send_error(404)
                        return
                    body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
                    (PRIVATE / 'local-capture.json').write_text(json.dumps({'num_ctx': body.get('options', {}).get('num_ctx')}))
                    reply = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': 'ok'}, 'finish_reason': 'stop'}], 'usage': {}}).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(reply)))
                    self.end_headers()
                    self.wfile.write(reply)

                def log_message(self, _format: str, *_args: object) -> None:
                    return

            with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
                base = f'http://127.0.0.1:{server.server_port}'
                for pages in snapshot.values():
                    for release in pages[0]:
                        for asset in release['assets']:
                            asset['browser_download_url'] = base + '/assets/' + asset['name']
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                child_env['MINERVA_REQUIRED_RELEASES_URL'] = base
                child_env['MINERVA_LIVE_LOCAL_URL'] = base
                import_env = {k: v for k, v in child_env.items()
                              if k not in ('MINERVA_TEST_USERNAME', 'MINERVA_TEST_PASSWORD')}
                stage = 'imports'
                try:
                    for _ in range(2):
                        subprocess.run(['godot', '--headless', '--path', str(repo / 'src'), '--import'],
                                       stdout=setup, stderr=subprocess.STDOUT, env=import_env, timeout=360, check=True)
                    with (PRIVATE / 'observer-check.log').open('w') as check_log:
                        check = subprocess.run(['godot', '--headless', '--path', str(repo / 'src'),
                                                '--check-only', '--script', 'res://test/live_context_compaction.gd'],
                                               stdout=check_log, stderr=subprocess.STDOUT, env=import_env, timeout=60, check=False)
                    check_text = (PRIVATE / 'observer-check.log').read_text()
                    summary['observer_check_exit'] = check.returncode
                    summary['observer_check_script_errors'] = 'SCRIPT ERROR:' in check_text
                    if check.returncode or summary['observer_check_script_errors']:
                        raise RuntimeError('Observer syntax prerequisite failed')
                    with (PRIVATE / 'display.log').open('w') as log:
                        display = subprocess.Popen(['Xvfb', ':97', '-screen', '0', '1600x1000x24', '-nolisten', 'tcp'],
                                                   stdout=log, stderr=subprocess.STDOUT, env=safe_env)
                    child_env['DISPLAY'] = ':97'
                    time.sleep(.3)
                    stage = 'gui_login_discovery'
                    with (PRIVATE / 'app.log').open('w') as log:
                        app = subprocess.Popen(['godot', '--path', str(repo / 'src'), '--rendering-method', 'gl_compatibility'],
                                               stdout=log, stderr=subprocess.STDOUT, env=child_env)
                    stage = 'live_acceptance'
                    return exercise(PRIVATE, app, time.monotonic() + 1050)
                finally:
                    retire(app)
                    retire(display)
                    server.shutdown()
                    thread.join(timeout=10)
    except (OSError, ValueError, KeyError, StopIteration, AssertionError, RuntimeError,
            http.client.HTTPException, subprocess.SubprocessError) as error:
        summary['failure_stage'] = stage
        summary['failure_type'] = type(error).__name__  # No raw exception/body/token material.
        return 90
    finally:
        summary['app_script_errors'] = ((PRIVATE / 'app.log').exists()
                                        and 'SCRIPT ERROR:' in (PRIVATE / 'app.log').read_text(errors='replace'))
        Path('/out/driver.json').write_text(json.dumps(summary, indent=2) + '\n')
        print('Isolated experiment ended; only metadata retained in /out.', flush=True)


if __name__ == '__main__':
    raise SystemExit(run())
