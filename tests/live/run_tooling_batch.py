"""SOPS-environment launcher for the single live Tooling acceptance test.

No credentials are accepted in arguments. The existing agent launcher owns
Core egress, inherited-value masking, finalization and job deadlines.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


def identity_free(raw: str, values: tuple[str, str]) -> bool:
    return (not any(value.lower() in raw.lower() for value in values)
            and not re.search(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', raw)
            and not re.search(r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', raw))


def launch(args: argparse.Namespace) -> int:
    if not os.environ.get('MINERVA_TEST_PASSWORD'):
        raise RuntimeError('Invoke through sops exec-env with the approved test environment')
    sys.path.insert(0, str(args.test_env_dir.resolve()))
    from test_env import get_test_credentials
    account = get_test_credentials()  # Password is already inherited, so no decryption fallback.
    values = (account.username, account.password)
    repo = Path(__file__).resolve().parents[2]
    agent = [sys.executable, '-B', str(repo / 'scripts/agent-container/agent.py')]
    safe_env = {k: v for k, v in os.environ.items() if k not in ('MINERVA_TEST_USERNAME', 'MINERVA_TEST_PASSWORD')}
    status = subprocess.run([*agent, 'status', args.session, '--json'], env=safe_env,
                            capture_output=True, text=True, check=True)
    session = json.loads(status.stdout)
    source = next(f['path'] for f in session['folders'] if f['host'] == str(repo))
    subprocess.run(['git', '-C', source, 'fetch', str(repo), args.rev], env=safe_env, check=True, capture_output=True)
    assets = Path(source) / '.live-tooling-assets'
    assets.mkdir(exist_ok=True)
    pins = json.loads((repo / 'tests/live/tooling-pins.json').read_text())
    for pin in pins:
        artifact = args.assets / pin['asset']
        if hashlib.sha256(artifact.read_bytes()).hexdigest() != pin['sha256']:
            raise RuntimeError('Pinned plugin digest mismatch')
        shutil.copyfile(artifact, assets / pin['asset'])
        (assets / (pin['asset'] + '.sha256')).write_text(pin['sha256'] + '\n')
    args.evidence.mkdir(parents=True, exist_ok=False)  # One attempt per evidence directory.
    (args.evidence / 'attempt.json').write_text(json.dumps({'revision': args.rev, 'session': args.session, 'attempt': 1}) + '\n')
    environment = dict(os.environ)
    environment['MINERVA_TEST_USERNAME'] = account.username
    command = [*agent, 'run-job', args.session, '--rev', args.rev, '--network', 'core',
               '--env-from', 'MINERVA_TEST_USERNAME', '--env-from', 'MINERVA_TEST_PASSWORD',
               '--seconds', '1200', '--memory', '8g', '--cpus', '4',
               '--command', 'python3 -B tests/live/tooling_batch.py', '--json']
    process = subprocess.run(command, env=environment, capture_output=True, text=True, check=False)
    if not identity_free(process.stdout, values):
        raise RuntimeError('Launcher output withheld by identity scan')
    result: dict[str, Any] = json.loads(process.stdout)
    job = result.get('job', {})
    if not job.get('final'):
        raise RuntimeError('Private job was not finalized; artifacts withheld')
    out = Path(job['log']).parent
    metadata: dict[str, Any] = {}
    scan: dict[str, Any] = {'identity_found': False, 'finalized': True, 'files': {}}
    for name in ('report.json', 'driver.json'):
        path = out / name
        if not path.exists():
            raise RuntimeError('Required report absent; not an expected RED')
        raw = path.read_text()
        if not identity_free(raw, values):
            raise RuntimeError('Report withheld by identity scan')
        metadata[name] = json.loads(raw)
        scan['files'][name] = hashlib.sha256(path.read_bytes()).hexdigest()
    # No artifact is copied or printed until BOTH reports passed the scan.
    for name in metadata:
        shutil.copyfile(out / name, args.evidence / name)
    (args.evidence / 'identity-scan.json').write_text(json.dumps(scan, indent=2) + '\n')
    (args.evidence / 'launcher.json').write_text(json.dumps(result, indent=2) + '\n')
    report, driver = metadata['report.json'], metadata['driver.json']
    expected_red = (report.get('status') == 'red' and report.get('assertion') == 'docket_updated_before_spawn'
                    and job['result'].get('exit_code') == 1)
    valid = (not driver.get('failure_stage') and not driver.get('app_script_errors')
             and driver.get('observer_check_exit') == 0 and not driver.get('observer_check_script_errors'))
    matched = valid and (expected_red if args.expected == 'red' else report.get('status') == 'green')
    receipt = {'job': job['job'], 'status': report.get('status'), 'assertion': report.get('assertion'),
               'expected': args.expected, 'expectation_met': matched, 'identity_scan_passed': True,
               'app_script_errors': driver.get('app_script_errors'), 'evidence': str(args.evidence)}
    (args.evidence / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))
    return 0 if matched else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', required=True)
    parser.add_argument('--rev', required=True, help='Reviewed immutable test/product commit')
    parser.add_argument('--test-env-dir', type=Path, required=True, help='Approved test_env.py directory')
    parser.add_argument('--assets', type=Path, required=True, help='Public plugin archives matching pins.json')
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--expected', choices=['red', 'green'], required=True)
    args = parser.parse_args()
    try:
        return launch(args)
    except (OSError, ValueError, KeyError, StopIteration, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({'status': 'launcher_failure', 'type': type(error).__name__}))
        return 90


if __name__ == '__main__':
    raise SystemExit(main())
