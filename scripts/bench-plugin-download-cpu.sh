#!/usr/bin/env bash
# CPU cost of a slow plugin download, before and after PluginDownloader.
#
#   scripts/bench-plugin-download-cpu.sh [SIZE_MIB] [RATE_MIB_PER_S]
#
# Serves SIZE_MIB (default 64) of random bytes at RATE_MIB_PER_S (default 8)
# from src/test/fixtures/throttled_http_server.py, downloads it headless once
# per mode (src/test/bench_plugin_download_cpu.gd), and prints each mode's
# user+sys CPU seconds, wall seconds, and CPU as a percent of one core. Both
# modes include Godot's own startup, so compare them with each other, not
# with zero. Runs on Linux and macOS; set GODOT to pick the binary.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
size_mib="${1:-64}"
rate_mib="${2:-8}"
work="$(mktemp -d)"
port=$(( 30000 + RANDOM % 20000 ))
server=
trap 'kill "$server" 2>/dev/null; rm -rf "$work"' EXIT

python3 -c "import os,sys; open(sys.argv[1],'wb').write(os.urandom(int(sys.argv[2]) << 20))" \
	"$work/source.bin" "$size_mib"
python3 "$REPO_ROOT/src/test/fixtures/throttled_http_server.py" "$work/source.bin" "$port" \
	--rate $(( rate_mib << 20 )) &
server=$!
for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.1; done

echo "size=${size_mib}MiB rate=${rate_mib}MiB/s host=$(uname -sm)"
for mode in httprequest downloader; do
	TIMEFORMAT="%U %S %R"
	times=$( { time "$GODOT" --headless --path "$REPO_ROOT/src" --script test/bench_plugin_download_cpu.gd \
		-- "$mode" "http://127.0.0.1:$port/plugin.tar.gz" "$work/$mode.bin" >/dev/null 2>&1; } 2>&1 )
	cmp -s "$work/source.bin" "$work/$mode.bin" || { echo "$mode: download incomplete" >&2; exit 1; }
	read -r user sys real <<<"$times"
	awk -v m="$mode" -v u="$user" -v s="$sys" -v r="$real" \
		'BEGIN { printf "%-12s cpu=%.2fs wall=%.2fs cpu/core=%.1f%%\n", m, u + s, r, 100 * (u + s) / r }'
done
