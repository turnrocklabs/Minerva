"""One live Tooling e2e (minerva:01a17c3c2d51 / 55b1); no mocks or model turns in B1.

Run via run_tooling_batch.py. Credentials and GUI logs stay on exec tmpfs.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import signal
import socket
import subprocess
import threading
import time
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, TypeVar
from urllib.parse import urlsplit

from context_compaction import GoalFailure, read_json, retire, rpc

T = TypeVar('T')

INPUTS = Path(__file__).resolve().parent
PRIVATE = Path('/tmp/live-tooling')
ASSETS = Path('/src/.live-tooling-assets')


def run() -> int:
    PRIVATE.mkdir(mode=0o700)
    report: dict[str, Any] = {'status': 'running', 'checks': [], 'launches': []}
    driver: dict[str, Any] = {'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode().strip()}
    safe_env = {k: v for k, v in os.environ.items() if k not in ('MINERVA_TEST_USERNAME', 'MINERVA_TEST_PASSWORD')}
    child_env = dict(os.environ)
    app = display = None
    server = None
    app_logs: list[Path] = []
    deadline = time.monotonic() + 1050
    session: dict[str, str] = {}
    port, call_id = 0, 0
    repo = Path.cwd()
    stage = 'assets'
    user = PRIVATE / 'xdg_data_home/godot/app_userdata/Minerva'
    registration = user.with_name('Docket') / 'instance.json'

    def wait(predicate: Callable[[], T]) -> T:
        while time.monotonic() < deadline:
            if app is not None and app.poll() is not None:
                raise RuntimeError('GUI exited before observation')
            stopped = read_json(PRIVATE / 'stop.json')
            if stopped:
                driver['prerequisite'] = stopped
                raise RuntimeError('Observer prerequisite failed')
            result = predicate()
            if result:
                return result
            time.sleep(.1)
        raise TimeoutError('Live Tooling deadline')

    def check(condition: bool, assertion: str) -> None:
        report['checks'].append({'assertion': assertion, 'passed': condition})
        if not condition:
            report['assertion'] = assertion
            raise GoalFailure(assertion)

    def tool(name: str, **arguments: object) -> dict[str, Any]:
        nonlocal call_id
        call_id += 1
        return rpc(port, 'tools/call', {'name': name, 'arguments': arguments}, session, call_id)

    def docket() -> dict[str, Any]:
        return next(p for p in tool('minerva_plugin_list')['plugins'] if p['id'] == 'docket')

    def end_docket() -> None:
        # The real launcher detached this process. Retire only its verified private
        # profile, never an arbitrary discovered PID or any host process.
        record = json.loads(registration.read_text())
        pid = int(record['pid'])
        profile = Path(record['profile'])
        environ = Path(f'/proc/{pid}/environ').read_bytes().split(b'\0')
        if profile != registration.parent or ('XDG_DATA_HOME=' + child_env['XDG_DATA_HOME']).encode() not in environ:
            raise RuntimeError('Refusing to stop a process outside the owned profile')
        os.kill(pid, signal.SIGTERM)
        until = time.monotonic() + 10
        while time.monotonic() < until and Path(f'/proc/{pid}').exists():
            try:
                if Path(f'/proc/{pid}/stat').read_text().split()[2] == 'Z':
                    break
            except FileNotFoundError:
                break
            time.sleep(.1)
        else:
            if Path(f'/proc/{pid}').exists():
                raise RuntimeError('Owned Docket did not retire')

    def launch() -> None:
        nonlocal app, port, call_id, session
        for name in ('ready', 'observed', 'stop'):
            # Truncate only this driver's own protocol files, with no directory deletion.
            (PRIVATE / (name + '.json')).write_text('null')
        log_path = PRIVATE / f'app-{len(app_logs)}.log'
        app_logs.append(log_path)
        with log_path.open('w') as log:
            app = subprocess.Popen(['godot', '--path', str(repo / 'src'), '--rendering-method', 'gl_compatibility'],
                                   env=child_env, stdout=log, stderr=subprocess.STDOUT)
        ready = wait(lambda: read_json(PRIVATE / 'ready.json'))
        port, call_id, session = int(ready['port']), 1, {}
        rpc(port, 'initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                                'clientInfo': {'name': 'live-tooling-e2e', 'version': '1'}}, session, call_id)
        report['launches'].append({'plugin': docket(), 'observer': wait(lambda: read_json(PRIVATE / 'observed.json'))})

    try:
        pins = json.loads((INPUTS / 'tooling-pins.json').read_text())
        for pin in pins:
            if hashlib.sha256((ASSETS / pin['asset']).read_bytes()).hexdigest() != pin['sha256']:
                raise RuntimeError('Pinned archive mismatch')
        stage = 'native_setup'
        with (PRIVATE / 'setup.log').open('w') as log:
            subprocess.run(['python3', '-B', 'scripts/container-build/dev-natives.py'], env=safe_env,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
            project = repo / 'src/project.godot'
            marker = 'WatcherRuntime="*res://Scripts/Services/Watcher/WatcherRuntime.gd"'
            original = project.read_text()
            if original.count(marker) != 1:
                raise RuntimeError('Observer installation marker missing')
            shutil.copyfile(INPUTS / 'tooling_observer.gd', repo / 'src/test/live_tooling_observer.gd')
            project.write_text(original.replace(marker, marker + '\nLiveToolingObserver="*res://test/live_tooling_observer.gd"'))
            for key in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME'):
                directory = PRIVATE / key.lower()
                directory.mkdir()
                child_env[key] = str(directory)
            user.mkdir(parents=True)
            (user / 'config_file.cfg').write_text('[Voice]\nturnrock_enabled=false\nalways_listening=false\n[HCP]\nauto_connect=false\n')
            disabled = [{'name': n, 'type': 'http', 'url': 'http://127.0.0.1:9', 'enabled': False,
                         'auto_connect': False, 'origin': 'known'} for n in ('nudge', 'cobrowser')]
            (user / 'mcp_config.json').write_text(json.dumps({'version': 3, 'servers': disabled}))
            registration.parent.mkdir()
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                (registration.parent / 'docket_prefs.json').write_text(json.dumps({'mcp_port': probe.getsockname()[1]}))
            fixture = json.loads((INPUTS / 'tooling-releases.json').read_text())
            release_file = PRIVATE / 'releases.json'

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
                        repo = path.removeprefix('/repos/').removesuffix('/releases')
                        body = json.dumps(json.loads(release_file.read_text()).get(repo, [[]])[0]).encode()
                    else:
                        self.send_error(404)
                        return
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

                def log_message(self, _format: str, *_args: object) -> None:
                    return

            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            base = f'http://127.0.0.1:{server.server_port}'
            snapshot = fixture['phase1']
            for release in [*(r for pages in snapshot.values() for r in pages[0]), fixture['new_docket']]:
                for asset in release['assets']:
                    asset['browser_download_url'] = base + '/assets/' + asset['name']
            release_file.write_text(json.dumps(snapshot))
            threading.Thread(target=server.serve_forever, daemon=True).start()
            child_env['MINERVA_REQUIRED_RELEASES_URL'] = base
            import_env = {k: v for k, v in child_env.items() if k not in ('MINERVA_TEST_USERNAME', 'MINERVA_TEST_PASSWORD')}
            stage = 'imports'
            for _ in range(2):
                subprocess.run(['godot', '--headless', '--path', str(repo / 'src'), '--import'], env=import_env,
                               stdout=log, stderr=subprocess.STDOUT, timeout=360, check=True)
            with (PRIVATE / 'observer-check.log').open('w') as check_log:
                parsed = subprocess.run(['godot', '--headless', '--path', str(repo / 'src'), '--check-only',
                                         '--script', 'res://test/live_tooling_observer.gd'], env=import_env,
                                        stdout=check_log, stderr=subprocess.STDOUT, timeout=60, check=False)
            check_text = (PRIVATE / 'observer-check.log').read_text()
            driver.update(observer_check_exit=parsed.returncode, observer_check_script_errors='SCRIPT ERROR:' in check_text)
            if parsed.returncode or driver['observer_check_script_errors']:
                raise RuntimeError('Observer syntax prerequisite failed')
            display = subprocess.Popen(['Xvfb', ':97', '-screen', '0', '1600x1000x24', '-nolisten', 'tcp'],
                                       env=safe_env, stdout=log, stderr=subprocess.STDOUT)
            child_env['DISPLAY'] = ':97'
            time.sleep(.3)
            stage = 'launch_1'
            launch()
            check(docket()['version'] == '0.3.0-rc.30.plugin.2', 'initial_old_install')
            retire(app)
            snapshot['turnrocklabs/Minerva'][0].append(fixture['new_docket'])
            release_file.write_text(json.dumps(snapshot))
            launch()
            check(docket()['version'] == '0.3.0-rc.30.plugin.2', 'owner_run_version_unchanged')
            end_docket()
            retire(app)
            launch()
            status = docket()
            observed = wait(lambda: read_json(PRIVATE / 'observed.json'))
            check(status['version'] == '0.3.0-rc.32' and status.get('attached_version') == '0.3.0-rc.32'
                  and observed['started_versions'] == ['0.3.0-rc.32'], 'docket_updated_before_spawn')
            end_docket()
            wait(lambda: not docket().get('attached', True) and not docket().get('attach_refused', True))
            check(True, 'docket_stop_clears_attachment')
            installed = tool('minerva_plugin_marketplace_install', url=base + '/assets/' + pins[-1]['asset'], auto_confirm_skills=True)
            while not installed.get('done'):
                installed = tool('minerva_plugin_marketplace_job', job_id=installed['job_id'])
            if not installed.get('ok'):
                raise RuntimeError('Code Tools install failed')
            plugins = tool('minerva_plugin_list')['plugins']
            if (not next(p for p in plugins if p['id'] == 'codetools')['running']
                    and not tool('minerva_plugin_start', id='codetools').get('ok')):
                raise RuntimeError('Code Tools start failed')
            before = wait(lambda: read_json(PRIVATE / 'observed.json'))['active']
            browse = tool('minerva_tool_search', query='*', activate=False, limit=500)
            time.sleep(.2)
            after = wait(lambda: read_json(PRIVATE / 'observed.json'))['active']
            check(before == after and bool(browse.get('tools')) and all('description' in t and 'plugin_id' in t for t in browse['tools']), 'browse_without_activation')
            invalid = tool('minerva_tool_search', query='*', category='no_such_category')
            check(invalid.get('success') is False and bool(invalid.get('categories')), 'strict_unknown_category')
            tools = tool('minerva_tool_search', plugin='Code Tools', activate=False)
            check(len(tools.get('tools', [])) == 21 and all(t.get('plugin_id') == 'codetools' for t in tools['tools']), 'plugin_display_name_search')
            tool('minerva_plugin_stop', id='codetools')
            stopped = tool('minerva_tool_search', plugin='Code Tools', activate=False)
            check(len(stopped.get('tools', [])) == 21 and all(t.get('running') is False for t in stopped['tools']), 'stopped_plugin_manifest_search')
        report['status'] = 'green'
        return 0
    except GoalFailure:
        report['status'] = 'red'
        return 1
    except (OSError, ValueError, KeyError, StopIteration, RuntimeError, subprocess.SubprocessError) as error:
        report.update(status='harness_or_prerequisite_failure', failure_type=type(error).__name__)
        driver['failure_stage'] = stage
        driver['failure_errno'] = error.errno if isinstance(error, OSError) else None
        return 90
    finally:
        retire(app)
        retire(display)
        if server:
            server.shutdown()
        driver['app_script_errors'] = any('SCRIPT ERROR:' in p.read_text(errors='replace') for p in app_logs)
        # Version/status metadata only; the inherited-account launcher scans both files.
        Path('/out/report.json').write_text(json.dumps(report, indent=2) + '\n')
        Path('/out/driver.json').write_text(json.dumps(driver, indent=2) + '\n')


if __name__ == '__main__':
    raise SystemExit(run())
