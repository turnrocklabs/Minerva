"""Provision a session's missing profile tools inside its running dev
container, for agent.py's `provision` command. The image is never rebuilt.

A profile tool may carry a "provision" entry (readiness.load_profile checks
it): an official https download of a zip or tar archive, a checksum (inline,
or read from the channel's own checksum file), and the executable's path
inside the archive. Provisioning downloads it inside the session through the
gateway's egress proxy, verifies the checksum, unpacks it into
$MINERVA_AGENT_TOOLS/opt/TOOL-VERSION (the persistent session home's tools/,
the directory agent-upgrade also uses) and links $MINERVA_AGENT_TOOLS/bin/TOOL
to the executable. agent-env.sh puts that bin first on PATH, so the harness,
its shell and readiness's probe all find the provisioned version; it is
private to the session and survives restarts. An already unpacked version is
reused, never overwritten; nothing is deleted.
"""
import subprocess

import readiness

PROVISION_TIMEOUT_S = 900
MAX_LOG = 2000

# Arguments: tool, version, url, checksum, checksum_url, bin, version args.
# The last output line is "provisioned<TAB>PATH<TAB>VERSION LINE" on success.
INSTALL = r'''
set -euo pipefail
. "$MINERVA_PROBE_ENV" >/dev/null 2>&1
tool="$1" version="$2" url="$3" sum="$4" sums_url="$5" bin="$6" vargs="$7"
tools="${MINERVA_AGENT_TOOLS:-/agent-home/tools}"
dest="$tools/opt/$tool-$version"
mkdir -p "$tools/opt" "$tools/bin"
if [ ! -e "$dest/$bin" ]; then
	file="${url%%\?*}"; file="${file##*/}"
	work="$(mktemp -d)"
	echo "downloading $url"
	curl -fsSL --retry 2 -o "$work/$file" "$url"
	if [ -z "$sum" ]; then
		sum="$(curl -fsSL --retry 2 "$sums_url" | awk -v f="$file" '$2 == f || $2 == "*" f { print $1; exit }')"
		[ -n "$sum" ] || { echo "$sums_url lists no checksum for $file" >&2; exit 3; }
	fi
	case "${#sum}" in
		64) algo=sha256sum ;;
		128) algo=sha512sum ;;
		*) echo "checksum for $file is neither sha256 nor sha512" >&2; exit 3 ;;
	esac
	echo "$sum  $work/$file" | "$algo" -c - >/dev/null || { echo "checksum mismatch for $file" >&2; exit 3; }
	unpack="$(mktemp -d "$tools/opt/.unpack-XXXXXX")"
	case "$file" in
		*.zip) unzip -q "$work/$file" -d "$unpack" ;;
		*) tar -xf "$work/$file" -C "$unpack" ;;
	esac
	[ -f "$unpack/$bin" ] || { echo "$file has no $bin" >&2; exit 3; }
	chmod u+x "$unpack/$bin"
	mv -T "$unpack" "$dest"
fi
ln -sfn "$dest/$bin" "$tools/bin/$tool"
printf 'provisioned\t%s\t%s\n' "$tools/bin/$tool" "$("$tools/bin/$tool" $vargs </dev/null 2>&1 | head -n 1)"
'''


def provision(container, tools, wanted):
    """Provision each tool in `wanted` (names from `tools`, each with a
    provision entry) in the running container, one after another. Returns
    [{"tool", "ok", "path", "version", "detail"}]."""
    results = []
    for tool in wanted:
        spec = tools[tool]
        how = spec["provision"]
        try:
            run = subprocess.run(["docker", "exec", "-e", f"MINERVA_PROBE_ENV={readiness.ENV_SCRIPT}",
                                  container, "bash", "-c", INSTALL, "provision", tool, how["version"],
                                  how["url"], how["checksum"], how["checksum_url"], how["bin"],
                                  spec["version_args"]],
                                 capture_output=True, text=True, timeout=PROVISION_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            results.append({"tool": tool, "ok": False, "path": "", "version": "",
                            "detail": f"did not finish within {PROVISION_TIMEOUT_S} s"})
            continue
        last = run.stdout.strip().splitlines()[-1:] or [""]
        fields = last[0].split("\t")
        if run.returncode == 0 and len(fields) == 3 and fields[0] == "provisioned":
            version = readiness.version_of(fields[2])
            results.append({"tool": tool, "ok": True, "path": fields[1][:readiness.MAX_FIELD],
                            "version": version, "detail": f"{version or 'present'} from {how['url']}"})
        else:
            why = (run.stderr.strip() or run.stdout.strip() or f"exit {run.returncode}")[-MAX_LOG:]
            results.append({"tool": tool, "ok": False, "path": "", "version": "", "detail": why})
    return results
