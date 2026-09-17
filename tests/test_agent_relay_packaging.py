#!/usr/bin/env python3
"""Focused packaging contract for the bundled Agent Relay worker."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "src/plugins/agent-relay/scripts/package-runtime.py"
SPEC = importlib.util.spec_from_file_location("agent_relay_package", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


WORKER = r'''#!/usr/bin/env python3
import json, sys
state_file = None
i = 1
while i < len(sys.argv):
    if sys.argv[i] == "--state-file":
        state_file = sys.argv[i + 1]
        i += 2
    else:
        raise SystemExit(2)
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        result = {"protocolVersion":"2024-11-05","capabilities":{},"serverName":"agent_relay","serverVersion":"test"}
    elif method == "tools/list":
        result = {"tools":[{"name":"minerva_agent_relay_watch_start"},{"name":"minerva_agent_relay_relay_ask"}]}
    elif method == "tools/call" and request.get("params",{}).get("name") == "minerva_agent_relay_profiles_list":
        result = {"content":[{"type":"text","text":"{\"profiles\":[]}"}]}
    elif method == "tools/call" and request.get("params",{}).get("name") == "minerva_agent_relay_filter_set":
        with open(state_file, "w", encoding="utf-8") as handle:
            json.dump({"filter_rules":[{"name":"packaged-probe"}]}, handle)
        result = {"content":[{"type":"text","text":"{\"ok\":true}"}]}
    else:
        print(json.dumps({"jsonrpc":"2.0","id":request.get("id"),"error":{"code":-32601,"message":"unknown"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
'''


class AgentRelayPackagingTest(unittest.TestCase):
    def test_package_checks_protocol_and_target_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "stage"
            stage.mkdir()
            worker = stage / "agent-relay-plugin"
            worker.write_text(WORKER, encoding="utf-8")
            worker.chmod(worker.stat().st_mode | stat.S_IXUSR)
            (stage / "target-triple.txt").write_text("linux-x86_64\n", encoding="ascii")
            archive = root / "relay.tar.gz"

            PACKAGE.package("linux-x86_64", stage, archive)
            expected = archive.with_suffix(".gz.sha256").read_text(encoding="ascii").strip()
            self.assertEqual(expected, hashlib.sha256(archive.read_bytes()).hexdigest())
            with tarfile.open(archive, "r:gz") as bundle:
                self.assertEqual(
                    sorted(bundle.getnames()),
                    ["agent-relay-plugin", "target-triple.txt"],
                )

            (stage / "target-triple.txt").write_text("macos-arm64\n", encoding="ascii")
            with self.assertRaises(SystemExit):
                PACKAGE.verify("linux-x86_64", stage)


if __name__ == "__main__":
    unittest.main()
