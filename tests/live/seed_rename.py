"""One live seed/policy e2e for minerva:01a18b25d611; run_seed_rename.py owns it.

Uses the standalone-attach path: pinned official Docket rc.32 registers itself
before the real GUI starts. No login/model turn: observe ChatPane's Docket
prompt prerequisite instead. Fixtures and raw logs stay on job tmpfs. Vault
metadata preservation remains covered by Docket's MasterBootstrapPlan tests.
After launch A's collision observations, an explicit fixture repair establishes
an own-master baseline so the independent swap/recovery checks can run at red.
It never changes a recorded observation or any product source behaviour.
"""
from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
import shutil
import socket
import subprocess
import tarfile
import threading
import time
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, TypeVar
from urllib.parse import urlsplit

from context_compaction import read_json, retire, rpc

T = TypeVar('T')
INPUTS = Path(__file__).resolve().parent
PRIVATE = Path('/tmp/live-seed-rename')
ASSETS = Path('/src/.live-seed-assets')
UNENFORCED = 'policy unenforced'
SENTINEL = 'SEED-LEAK-7f3a'
USER_EDIT = 'USER-EDIT-91c2'
USER_OWN = 'USER-OWN-4b7d'
ASSERTIONS = (
    'master_attached', 'both_projects_listed', 'governed_call_proceeds', 'policy_enforced',
    'fresh_install_meta', 'seed_prompt_not_layered', 'seed_skill_not_ambiguous',
    'unenforced_call_proceeds', 'unenforced_no_policy_fields', 'unenforced_indicator',
    'secret_set_refused', 'legacy_untouched', 'enforcement_resumes',
    'existing_user_meta_kept', 'existing_user_items_kept', 'legacy_starts_degraded',
    'mcp_answers_without_login',
)


class Client:
    """All MCP payloads are dynamic external JSON, including refused tool results."""

    def __init__(self, port: int) -> None:
        self.port, self.sequence = port, 0
        self.session: dict[str, str] = {}
        self.request('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {},
                                   'clientInfo': {'name': 'seed-rename-e2e', 'version': '1'}})

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self.sequence += 1
        return rpc(self.port, method, params, self.session, self.sequence)

    def tool(self, name: str, **arguments: object) -> dict[str, Any]:
        return self.request('tools/call', {'name': name, 'arguments': arguments})

    def fixture(self, name: str, **arguments: object) -> dict[str, Any]:
        result = self.tool(name, **arguments)
        if 'error' in result or result.get('success') is False:
            raise RuntimeError('Docket fixture refused: ' + name)
        return result


def snapshot(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []
    return (next((r for r in records if r.get('_type') == 'meta'), {}),
            [r for r in records if r.get('_type') == 'item'])


def copy_fixture(source: Path, target: Path, project: str | None = None) -> None:
    # Only the fixture's meta name changes mechanically. Item changes use Docket.
    lines = source.read_text().splitlines(keepends=True)
    if project is not None:
        meta = json.loads(lines[0])
        meta['project'] = project
        lines[0] = json.dumps(meta, separators=(',', ':')) + '\n'
    target.write_text(''.join(lines))


def marker(observed: dict[str, Any]) -> bool:
    return any(UNENFORCED in str(p).lower() for p in observed['problems'])


class Harness:
    def __init__(self, repo: Path, env: dict[str, str], binary: Path, deadline: float,
                 report: dict[str, Any], driver: dict[str, Any]) -> None:
        self.repo, self.env, self.binary, self.deadline = repo, env, binary, deadline
        self.report, self.driver = report, driver
        self.app: subprocess.Popen | None = None
        self.docket: subprocess.Popen | None = None
        self.logs: list[Path] = []
        self.private = PRIVATE
        self.sequence = 0
        self.client: Client
        self.backend: Client
        self.user = PRIVATE

    def wait(self, predicate: Callable[[], T]) -> T:
        while time.monotonic() < self.deadline:
            for process in (self.app, self.docket):
                if process is not None and process.poll() is not None:
                    raise RuntimeError('Owned GUI/Docket exited before observation')
            if read_json(self.private / 'stop.json'):
                raise RuntimeError('Observer prerequisite failed')
            value = predicate()
            if value:
                return value
            time.sleep(.1)
        raise TimeoutError('Seed e2e deadline')

    def spawn(self, name: str, args: list[str], env: dict[str, str]) -> subprocess.Popen:
        path = self.private / (name + '.log')
        self.logs.append(path)
        with path.open('w') as log:
            return subprocess.Popen(args, env=env, cwd=self.private, stdout=log, stderr=subprocess.STDOUT)

    def start(self, scenario: str) -> None:
        self.private = PRIVATE / scenario
        self.private.mkdir()
        env = dict(self.env)
        for key in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME'):
            directory = self.private / key.lower()
            directory.mkdir()
            env[key] = str(directory)
        self.user = Path(env['XDG_DATA_HOME']) / 'godot/app_userdata/Minerva'
        self.user.mkdir(parents=True)
        (self.user / 'config_file.cfg').write_text('[Voice]\nturnrock_enabled=false\nalways_listening=false\n[HCP]\nauto_connect=false\n')
        disabled = [{'name': n, 'type': 'http', 'url': 'http://127.0.0.1:9', 'enabled': False,
                     'auto_connect': False, 'origin': 'known'} for n in ('nudge', 'cobrowser')]
        (self.user / 'mcp_config.json').write_text(json.dumps({'version': 3, 'servers': disabled}))
        env['MINERVA_SEED_PRIVATE'] = str(self.private)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        self.docket = self.spawn('docket', [str(self.binary), '--headless', '--serve', '--file',
                                          str(self.private / 'anchor.dct'), '--port', str(port)], env)
        registration = self.user.with_name('Docket') / 'instance.json'
        record = self.wait(lambda: read_json(registration))
        if record['pid'] != self.docket.pid or int(record['endpoint']['port']) != port:
            raise RuntimeError('Docket registration does not belong to this driver')
        self.backend = Client(port)
        self.backend.fixture('docket_schema_declare', schema=json.loads((self.repo / 'src/Data/docket_schema.json').read_text()), version='seed-e2e')
        self.child_env = env

    def launch(self) -> dict[str, Any]:
        self.sequence = 0
        self.app = self.spawn('app', ['godot', '--path', str(self.repo / 'src'), '--rendering-method', 'gl_compatibility'], self.child_env)
        ready = self.wait(lambda: read_json(self.private / 'ready.json'))
        if ready.get('attached') is not True:
            raise RuntimeError('Standalone Docket attach prerequisite failed')
        self.client = Client(int(ready['port']))
        observed = self.observe()
        self.report['launches'].append({'scenario': self.private.name, 'attached': True,
                                       'state': observed['state'], 'problems': observed['problems']})
        return observed

    def observe(self, action: str = 'snapshot') -> dict[str, Any]:
        self.sequence += 1
        pending = self.private / 'command.pending'
        pending.write_text(json.dumps({'sequence': self.sequence, 'action': action}))
        pending.replace(self.private / 'command.json')
        def answer() -> dict[str, Any] | None:
            value = read_json(self.private / 'answer.json')
            return value['result'] if value and value.get('sequence') == self.sequence else None
        return self.wait(answer)

    def check(self, assertion: str, passed: bool) -> None:
        self.report['checks'].append({'assertion': assertion, 'passed': bool(passed)})

    def bootstrap(self) -> None:
        source = self.private / 'own-shipment.dct'
        copy_fixture(self.repo / 'src/Data/master.dct', source, 'master')
        self.backend.fixture('docket_project_bootstrap', path=str(self.user / 'master.dct'),
                             content=base64.b64encode(source.read_bytes()).decode(), update_mode='replace_shipped')

    def close(self) -> None:
        retire(self.app)
        self.app = None
        retire(self.docket)
        self.docket = None

    def scenario_a(self, seed_meta: dict[str, Any], items: list[dict[str, Any]]) -> None:
        self.start('a')
        seed = self.private / 'seed.dct'
        copy_fixture(self.repo / 'src/Data/master.dct', seed)
        name = str(seed_meta['project'])
        self.backend.fixture('docket_project_add', path=str(seed), create=False)
        prompt = next(i for i in items if i.get('type') == 'prompt' and i.get('status') == 'active')
        self.backend.fixture('docket_update', project=name, id=prompt['id'], prompt_text=prompt['prompt_text'] + '\n' + SENTINEL)
        read = self.backend.fixture('docket_get', project=name, id=prompt['id'], include=[])
        if SENTINEL not in read.get('prompt_text', ''):
            raise RuntimeError('Prompt fixture mutation missing')
        observed = self.launch()
        tools = self.client.request('tools/list', {}).get('tools', [])
        self.check('mcp_answers_without_login', bool(tools))
        self.check('master_attached', observed['master_path'] == str(self.user / 'master.dct') and not observed['problems']
                   and observed['chat_prompt_readable'])
        projects = self.backend.fixture('docket_project_list')['projects']
        self.check('both_projects_listed', any(p['name'] == 'master' and p['path'] == str(self.user / 'master.dct') for p in projects)
                   and any(p['name'] == name and p['path'] == str(seed) for p in projects) and name != 'master')
        call = self.client.tool('minerva_clock')
        self.check('governed_call_proceeds', call.get('success') is True and isinstance(call.get('unix_timestamp'), (int, float)))
        reload = self.client.tool('minerva_policy_reload')
        self.check('policy_enforced', reload.get('success') is True and reload.get('rules_loaded', 0) > 0)
        meta, current = snapshot(self.user / 'master.dct')
        self.check('fresh_install_meta', bool(meta) and meta.get('project') == 'master' and len(current) == len(items)
                   and all(meta.get(k) == seed_meta[k] for k in ('version', 'id_prefix')))
        composed = observed['prompt']
        self.check('seed_prompt_not_layered', bool(composed.get('prompt')) and 'error' not in composed and SENTINEL not in composed['prompt'])
        skill = next(i for i in items if i.get('type') == 'skill')
        found = self.client.tool('minerva_get_skill', title=skill['title'])
        self.check('seed_skill_not_ambiguous', found.get('success') is True and found.get('id') == skill['id']
                   and found.get('origin') == 'docket' and found.get('project') == 'master')
        self.driver['initial_product_errors'] = {'clock': call.get('error_code', ''), 'policy': reload.get('error_code', ''),
                                                 'bootstrap_collision': any('name already loaded' in p for p in observed['problems'])}
        # Establish an independent swap baseline even when the first bootstrap failed.
        if any(p['name'] == 'master' for p in projects):
            self.backend.fixture('docket_project_remove', name='master')
        self.bootstrap()
        reconnect = self.observe('reconnect')
        if 'error' in reconnect:
            raise RuntimeError('Owned Docket reconnect failed')
        baseline = self.observe()
        if baseline['master_path'] != str(self.user / 'master.dct'):
            raise RuntimeError('Independent swap baseline has no own master')
        self.driver['swap_baseline_reconnected'] = True
        self.backend.fixture('docket_project_remove', name='master')
        legacy = self.private / 'legacy.dct'
        copy_fixture(self.repo / 'src/Data/master.dct', legacy, 'master')
        self.backend.fixture('docket_project_add', path=str(legacy), create=False)
        before = legacy.read_bytes()
        call = self.client.tool('minerva_clock')
        self.check('unenforced_call_proceeds', call.get('success') is True and isinstance(call.get('unix_timestamp'), (int, float)))
        self.check('unenforced_no_policy_fields', call.get('success') is True and not {'allowed', 'effect', 'policy'} & call.keys())
        observed = self.observe()
        self.check('unenforced_indicator', marker(observed))
        secret = self.client.tool('minerva_docket_secret_set', handle='user/e2e', value='x')
        refused = secret.get('success') is False or 'error' in secret or secret.get('allowed') is False
        self.check('secret_set_refused', refused and str(self.user / 'master.dct') in json.dumps(secret))
        self.check('legacy_untouched', legacy.read_bytes() == before)
        self.backend.fixture('docket_project_remove', name='master')
        self.backend.fixture('docket_project_add', path=str(self.user / 'master.dct'), create=False)
        reload = self.client.tool('minerva_policy_reload')
        observed = self.observe()
        self.check('enforcement_resumes', reload.get('success') is True and reload.get('rules_loaded', 0) > 0
                   and not marker(observed) and observed['master_path'] == str(self.user / 'master.dct'))
        self.close()

    def scenario_b(self, items: list[dict[str, Any]]) -> None:
        self.start('b')
        self.bootstrap()
        skill = next(i for i in items if i.get('type') == 'skill')
        self.backend.fixture('docket_update', project='master', id=skill['id'], description=USER_EDIT)
        own = self.backend.fixture('docket_create', project='master', type='skill', title='User own skill e2e', description=USER_OWN)
        own_id = own['id']
        if self.backend.fixture('docket_get', project='master', id=skill['id'], include=[]).get('description') != USER_EDIT:
            raise RuntimeError('Custom user edit missing')
        self.backend.fixture('docket_project_remove', name='master')
        before, _ = snapshot(self.user / 'master.dct')
        observed = self.launch()
        after, current = snapshot(self.user / 'master.dct')
        report = observed['master_report']
        advanced = report.get('master_update_status') in ('authoritative', 'partial')
        self.check('existing_user_meta_kept', after.get('project') == 'master' and bool(before.get('master_bootstrap_state'))
                   and (after.get('master_bootstrap_state') == before['master_bootstrap_state'] or advanced))
        restored = next((i for i in current if i['id'] == skill['id']), {})
        preserved = next((i for i in current if i['id'] == own_id), {})
        self.check('existing_user_items_kept', restored.get('description') == skill['description']
                   and USER_EDIT not in restored.get('description', '') and preserved.get('description') == USER_OWN
                   and report.get('master_update_status') == 'authoritative')
        self.close()

    def scenario_c(self) -> None:
        self.start('c')
        legacy = self.private / 'legacy.dct'
        copy_fixture(self.repo / 'src/Data/master.dct', legacy, 'master')
        self.backend.fixture('docket_project_add', path=str(legacy), create=False)
        observed = self.launch()
        call = self.client.tool('minerva_clock')
        self.check('legacy_starts_degraded', bool(observed['problems']) and any(str(legacy) in p for p in observed['problems'])
                   and call.get('success') is True and isinstance(call.get('unix_timestamp'), (int, float)))
        self.close()


def run() -> int:
    if not os.environ.get('MINERVA_JOB_ID') or Path.cwd().parent != Path('/tmp/job'):
        raise SystemExit('Run only through the isolated agent job launcher')
    PRIVATE.mkdir(mode=0o700)
    repo = Path.cwd()
    env = {k: v for k, v in os.environ.items() if k not in ('MINERVA_TEST_USERNAME', 'MINERVA_TEST_PASSWORD')}
    report: dict[str, Any] = {'status': 'running', 'checks': [], 'launches': []}
    driver: dict[str, Any] = {'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], env=env).decode().strip()}
    harness = None
    display = None
    server = None
    stage = 'assets'
    try:
        pins = json.loads((INPUTS / 'seed-rename-pins.json').read_text())
        for pin in pins:
            if hashlib.sha256((ASSETS / pin['asset']).read_bytes()).hexdigest() != pin['sha256']:
                raise RuntimeError('Pinned archive mismatch')
        binary_dir = PRIVATE / 'official'
        binary_dir.mkdir()
        with tarfile.open(ASSETS / pins[0]['asset']) as archive:
            for member in archive.getmembers():
                if member.isfile() and '/official/' in '/' + member.name and (member.name.endswith('/docket.x86_64') or member.name.endswith('.so')):
                    stream = archive.extractfile(member)
                    if stream is None:
                        raise RuntimeError('Official binary archive unreadable')
                    target = binary_dir / Path(member.name).name
                    target.write_bytes(stream.read())
                    target.chmod(0o755)
        binary = binary_dir / 'docket.x86_64'
        if not binary.is_file():
            raise RuntimeError('Pinned official Docket binary absent')
        fixture = json.loads((INPUTS / 'seed-rename-releases.json').read_text())

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                route = urlsplit(self.path).path
                if route.startswith('/assets/'):
                    target = ASSETS / Path(route).name
                    body = target.read_bytes() if target.is_file() else None
                elif route.startswith('/repos/') and route.endswith('/releases'):
                    body = json.dumps(fixture.get(route[7:-9], [[]])[0]).encode()
                else:
                    body = None
                if body is None:
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
        for pages in fixture.values():
            for release in pages[0]:
                for asset in release['assets']:
                    asset['browser_download_url'] = base + '/assets/' + asset['name']
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env['MINERVA_REQUIRED_RELEASES_URL'] = base
        env['DISPLAY'] = ':97'
        stage = 'native_setup'
        with (PRIVATE / 'setup.log').open('w') as log:
            subprocess.run(['python3', '-B', 'scripts/container-build/dev-natives.py'], env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            project = repo / 'src/project.godot'
            original = project.read_text()
            anchor = 'WatcherRuntime="*res://Scripts/Services/Watcher/WatcherRuntime.gd"'
            if original.count(anchor) != 1:
                raise RuntimeError('Observer install anchor missing')
            shutil.copyfile(INPUTS / 'seed_rename_observer.gd', repo / 'src/test/live_seed_rename_observer.gd')
            project.write_text(original.replace(anchor, anchor + '\nLiveSeedObserver="*res://test/live_seed_rename_observer.gd"'))
            for key in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME'):
                directory = PRIVATE / key.lower()
                directory.mkdir()
                env[key] = str(directory)
            stage = 'imports'
            for _ in range(2):
                subprocess.run(['godot', '--headless', '--path', str(repo / 'src'), '--import'], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=360, check=True)
            with (PRIVATE / 'observer-check.log').open('w') as checked:
                parsed = subprocess.run(['godot', '--headless', '--path', str(repo / 'src'), '--check-only', '--script', 'res://test/live_seed_rename_observer.gd'], env=env, stdout=checked, stderr=subprocess.STDOUT, timeout=60, check=False)
            driver.update(observer_check_exit=parsed.returncode, observer_check_script_errors='SCRIPT ERROR:' in (PRIVATE / 'observer-check.log').read_text())
            if parsed.returncode or driver['observer_check_script_errors']:
                raise RuntimeError('Observer parse prerequisite failed')
            display = subprocess.Popen(['Xvfb', ':97', '-screen', '0', '1600x1000x24', '-nolisten', 'tcp'], env=env, stdout=log, stderr=subprocess.STDOUT)
            time.sleep(.3)
            meta, items = snapshot(repo / 'src/Data/master.dct')
            harness = Harness(repo, env, binary, time.monotonic() + 1050, report, driver)
            for stage, operation in [('launch_a', lambda: harness.scenario_a(meta, items)),
                                     ('launch_b', lambda: harness.scenario_b(items)), ('launch_c', harness.scenario_c)]:
                operation()
            if {c['assertion'] for c in report['checks']} != set(ASSERTIONS) or len(report['checks']) != len(ASSERTIONS):
                raise RuntimeError('Assertion map incomplete')
            report['status'] = 'green' if all(c['passed'] for c in report['checks']) else 'red'
            return 0 if report['status'] == 'green' else 1
    except (OSError, ValueError, KeyError, StopIteration, RuntimeError, http.client.HTTPException, subprocess.SubprocessError) as error:
        report['status'] = 'harness_or_prerequisite_failure'
        driver.update(failure_stage=stage, failure_type=type(error).__name__)
        return 90
    finally:
        if harness:
            harness.close()
        retire(display)
        if server:
            server.shutdown()
        driver['app_script_errors'] = bool(harness and any('SCRIPT ERROR:' in p.read_text(errors='replace') for p in harness.logs))
        Path('/out/report.json').write_text(json.dumps(report, indent=2) + '\n')
        Path('/out/driver.json').write_text(json.dumps(driver, indent=2) + '\n')


if __name__ == '__main__':
    raise SystemExit(run())
