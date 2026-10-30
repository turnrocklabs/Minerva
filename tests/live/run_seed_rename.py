"""Launch the reviewed seed/policy e2e without credentials or network egress.

One invocation is one attempt in a fresh evidence directory. Raw GUI logs stay
on exec tmpfs; only scanned report/driver metadata leave the isolated job.
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
import time
from pathlib import Path
from typing import Any

from run_tooling_batch import identity_free
from seed_rename import ASSERTIONS


def launch(args: argparse.Namespace) -> int:
    if not re.fullmatch(r'[0-9a-f]{40}', args.rev):
        raise ValueError('Use the full reviewed immutable revision')
    repo = Path(__file__).resolve().parents[2]
    agent = [sys.executable, '-B', str(repo / 'scripts/agent-container/agent.py')]
    # Do not forward an accidentally inherited test identity, even on this offline lane.
    values = tuple(os.environ.get(k) or '\0' for k in ('MINERVA_TEST_USERNAME', 'MINERVA_TEST_PASSWORD'))
    env = {k: v for k, v in os.environ.items() if k not in ('MINERVA_TEST_USERNAME', 'MINERVA_TEST_PASSWORD')}
    status = subprocess.run([*agent, 'status', args.session, '--json'], env=env, capture_output=True, text=True, check=True)
    session = json.loads(status.stdout)
    source = next(f['path'] for f in session['folders'] if f['host'] == str(repo))
    subprocess.run(['git', '-C', source, 'fetch', str(repo), args.rev], env=env, capture_output=True, check=True)
    # Pins are read from the requested commit, not a potentially dirty host test file.
    raw_pins = subprocess.check_output(['git', '-C', str(repo), 'show', args.rev + ':tests/live/seed-rename-pins.json'], env=env)
    assets = Path(source) / '.live-seed-assets'
    assets.mkdir(exist_ok=True)
    for pin in json.loads(raw_pins):
        artifact = args.assets / pin['asset']
        if hashlib.sha256(artifact.read_bytes()).hexdigest() != pin['sha256']:
            raise RuntimeError('Pinned plugin digest mismatch')
        shutil.copyfile(artifact, assets / pin['asset'])
        (assets / (pin['asset'] + '.sha256')).write_text(pin['sha256'] + '\n')
    args.evidence.mkdir(parents=True, exist_ok=False)
    (args.evidence / 'attempt.json').write_text(json.dumps({'revision': args.rev, 'session': args.session, 'attempt': 1}) + '\n')
    process = subprocess.run([*agent, 'run-job', args.session, '--rev', args.rev, '--network', 'none',
                              '--seconds', '1800', '--memory', '8g', '--cpus', '4',
                              '--command', 'python3 -B tests/live/seed_rename.py', '--json'],
                             env=env, capture_output=True, text=True, check=True)
    result: dict[str, Any] = json.loads(process.stdout)
    job = result['job']
    job_id = job['job']
    deadline = time.monotonic() + 1860
    while not job.get('final') and time.monotonic() < deadline:
        time.sleep(2)
        queried = subprocess.run([*agent, 'job-status', args.session, job_id, '--json'], env=env,
                                 capture_output=True, text=True, check=True)
        job = json.loads(queried.stdout)
    if not job.get('final'):
        raise RuntimeError('Job did not finish within its outer deadline')
    if job.get('revision') != args.rev:
        raise RuntimeError('Executed revision differs from reviewed pin')
    out = Path(job['log']).parent
    metadata: dict[str, Any] = {}
    scan: dict[str, Any] = {'identity_found': False, 'files': {}}
    for name in ('report.json', 'driver.json'):
        path = out / name
        raw = path.read_text()
        if not identity_free(raw, values):
            raise RuntimeError('Report withheld by identity scan')
        metadata[name] = json.loads(raw)
        scan['files'][name] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not identity_free(json.dumps(job), values):
        raise RuntimeError('Job metadata withheld by identity scan')
    report, driver = metadata['report.json'], metadata['driver.json']
    checks = report.get('checks', [])
    flags = {c['assertion']: c['passed'] for c in checks}
    complete = len(checks) == len(ASSERTIONS) and set(flags) == set(ASSERTIONS)
    valid = (complete and not driver.get('failure_stage') and not driver.get('app_script_errors')
             and driver.get('observer_check_exit') == 0 and driver.get('observer_check_script_errors') is False
             and driver.get('revision') == args.rev and flags.get('mcp_answers_without_login') is True)
    product = driver.get('initial_product_errors', {})
    expected_red = (report.get('status') == 'red' and job['result'].get('exit_code') == 1
                    and product.get('bootstrap_collision') is True and product.get('clock') == 'policy_unavailable'
                    and not flags.get('master_attached') and not flags.get('governed_call_proceeds')
                    and not flags.get('unenforced_call_proceeds'))
    matched = valid and (expected_red if args.expected == 'red' else report.get('status') == 'green' and all(flags.values()))
    # Both reports and the job record pass scanning before any evidence is copied.
    for name in metadata:
        shutil.copyfile(out / name, args.evidence / name)
    (args.evidence / 'identity-scan.json').write_text(json.dumps(scan, indent=2) + '\n')
    (args.evidence / 'launcher.json').write_text(json.dumps(job, indent=2) + '\n')
    receipt = {'job': job_id, 'revision': args.rev, 'status': report.get('status'), 'checks': checks,
               'expected': args.expected, 'expectation_met': matched, 'identity_scan_passed': True,
               'evidence': str(args.evidence)}
    (args.evidence / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))
    return 0 if matched else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', required=True)
    parser.add_argument('--rev', required=True, help='Reviewed full commit SHA')
    parser.add_argument('--assets', type=Path, required=True)
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
