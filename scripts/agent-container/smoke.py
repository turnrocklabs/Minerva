#!/usr/bin/env python3
"""Benign boundary probes, run inside a dev container:
  docker exec minerva-agent-NAME python3 -B /opt/minerva-agent/smoke.py \
      --docket-item ID --docket-project minerva

Checks what the session can and cannot reach, using only calls that are
harmless even if the gateway were wrong: tools/list per service; two
DENIED-but-harmless tools (minerva_clock, docket_project_list) that must be
refused by the gateway; one Docket read; one Nudge read; and, unless
--no-egress, the egress proxy (a public host must tunnel, a
loopback literal must be refused) and a direct connection (must fail:
the container has no network). Prints one JSON report; exits non-zero if
any probe did not behave as expected.
"""
import argparse
import http.client
import json
import socket
import sys

EXPECTED_TOOLS = {
    "minerva": {"minerva_terminal_notify", "minerva_terminal_list", "minerva_get_note",
                "minerva_update_note", "minerva_append_note", "minerva_read_note_since"},
    "docket": {"docket_get", "docket_query", "docket_comment", "docket_create", "docket_update",
               "docket_transition", "docket_append", "docket_attach", "docket_detach", "docket_claim",
               "docket_release", "docket_reassign"},
    "nudge": {"nudge_get_hint", "nudge_set_hint", "nudge_query", "nudge_bump", "nudge_list_components"},
}
DENIED = -32001


def rpc(port, method, params=None, rid=1):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    body = {"jsonrpc": "2.0", "id": rid, "method": method}
    if params is not None:
        body["params"] = params
    conn.request("POST", "/mcp", json.dumps(body), {"Content-Type": "application/json"})
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    return json.loads(data) if data else {}


def call(port, tool, args):
    return rpc(port, "tools/call", {"name": tool, "arguments": args})


def connect_via_proxy(port, host):
    """The proxy's status line for CONNECT host:443."""
    with socket.create_connection(("127.0.0.1", port), timeout=20) as s:
        s.sendall(f"CONNECT {host}:443 HTTP/1.1\r\nHost: {host}:443\r\n\r\n".encode())
        return s.recv(64).split(b"\r\n", 1)[0].decode("latin-1")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--docket-item", required=True)
    parser.add_argument("--docket-project", required=True)
    parser.add_argument("--no-egress", action="store_true")
    parser.add_argument("--allowed-host", default="registry.npmjs.org")
    parser.add_argument("--denied-host", default="127.0.0.1")
    parser.add_argument("--ports", default="minerva=9315,docket=3010,nudge=8765,proxy=3128")
    args = parser.parse_args()
    ports = {k: int(v) for k, v in (p.split("=") for p in args.ports.split(","))}
    report = {}

    def check(name, ok, detail):
        report[name] = {"ok": bool(ok), "detail": detail}

    for service, expected in EXPECTED_TOOLS.items():
        try:
            listed = {t["name"] for t in rpc(ports[service], "tools/list")["result"]["tools"]}
            check(f"{service}_tools_list", listed <= expected and listed, sorted(listed))
        except Exception as exc:  # report, keep probing
            check(f"{service}_tools_list", False, repr(exc))
    for service, tool, targs in (("minerva", "minerva_clock", {}),
                                 ("docket", "docket_project_list", {})):
        try:
            reply = call(ports[service], tool, targs)
            check(f"{tool}_denied", reply.get("error", {}).get("code") == DENIED, reply.get("error"))
        except Exception as exc:
            check(f"{tool}_denied", False, repr(exc))
    try:
        reply = call(ports["docket"], "docket_get", {"id": args.docket_item, "project": args.docket_project})
        item = json.loads(reply["result"]["content"][0]["text"])
        check("docket_get", item.get("id") == args.docket_item, {"type": item.get("type")})
    except Exception as exc:
        check("docket_get", False, repr(exc))
    try:
        reply = call(ports["nudge"], "nudge_list_components", {})
        check("nudge_list_components", "result" in reply, sorted(reply) if isinstance(reply, dict) else None)
    except Exception as exc:
        check("nudge_list_components", False, repr(exc))
    if not args.no_egress:
        for label, host, want in (("egress_allowed", args.allowed_host, " 200 "),
                                  ("egress_denied", args.denied_host, " 403 ")):
            try:
                status = connect_via_proxy(ports["proxy"], host)
                check(label, want in status + " ", status)
            except Exception as exc:
                check(label, False, repr(exc))
        try:
            socket.create_connection(("1.1.1.1", 443), timeout=5).close()
            check("direct_egress_blocked", False, "connected")
        except OSError as exc:
            check("direct_egress_blocked", True, exc.strerror or repr(exc))
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if all(v["ok"] for v in report.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
