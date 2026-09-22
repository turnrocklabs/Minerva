#!/usr/bin/env bash
# Run functional suites and a source-tree app smoke in a throwaway container,
# beside (never against) a running Minerva.
#
#   scripts/container-test.sh run [options] [SUITE...]
#   scripts/container-test.sh stop NAME     # kill one run; others keep going
#   scripts/container-test.sh list          # running jobs
#   scripts/container-test.sh prune [DAYS]  # drop caches/results unused for DAYS (7)
#
# run options:
#   --rev REV       commit to test (default HEAD). Uncommitted edits are NOT
#                   tested — commit (a WIP commit is fine) first.
#   --name NAME     job name (default: generated); container is minerva-ct-NAME
#   --cpus N        CPU limit (default 4)
#   --memory SIZE   memory limit, no swap (default 8g)
#   --timeout SEC   whole-job deadline (default 1800)
#   --out DIR       results directory (default: <cache>/runs/NAME)
# SUITE is a path registered in scripts/run-functional-tests.sh or "app-smoke";
# the default is a small representative set (DEFAULT_SUITES below).
#
# Isolation: the container gets its own PID, network (--network none: only its
# own loopback, so two jobs and the live app can all use port 9315), user
# profile, HOME and Xvfb display. The host checkout is never mounted — the
# revision arrives as a read-only `git archive` snapshot, and the gitignored
# native binaries (terminal extension, sqlite, ffmpeg, CEF, staged runtimes)
# as read-only content-addressed copies taken at launch. The results directory
# is the only writable host mount. Caches live in
# ${MINERVA_CT_CACHE:-~/.cache/minerva-container-tests}.
#
# Results: <out>/run.json (revision, native hashes, image, limits, docker's own
# view of mounts/namespaces), <out>/results.json (per-suite strict verdicts, see
# container-test/accounting.py), <out>/logs/. Exit status is the job's: 0 only
# when every suite passed with at least one assertion and no skips.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/scripts/container-test"
CACHE="${MINERVA_CT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/minerva-container-tests}"
LABEL=minerva-container-test

DEFAULT_SUITES=(
	test/test_utf8_line_bytes.cpp
	test/test_plugin_bridge_limits.js
	test/test_mcp_http_transport.gd
	test/test_mcp_stdio_concurrency.gd
	test/test_terminal_session.gd
	test/test_terminal_notify.gd
	test/test_chat_groups_integration.gd
	app-smoke
)
# Gitignored runtime binaries a test run needs, relative to the repo root.
NATIVE_PATHS=(
	src/bin/libterminal.linux.template_debug.x86_64.so
	src/bin/libminerva-vt.so
	src/bin/minerva-json-schema-helper
	src/bin/minerva-host-pdf-linux
	src/addons/godot-sqlite/bin
	src/addons/ffmpeg/linux64
	src/addons/godot_cef/bin/x86_64-unknown-linux-gnu
	src/plugins/agent-relay/runtime-build/stage/linux-x86_64
	src/plugins/voice/runtime-build/stage/linux-x86_64
)

die() { echo "container-test: $*" >&2; exit 2; }

# content_hash PATH: sha256 over every file's relative path and content.
content_hash() {
	if [[ -d "$1" ]]; then
		(cd "$1" && find . \( -type f -o -type l \) -print0 | sort -z | xargs -0 -r sha256sum) | sha256sum | cut -c1-32
	else
		sha256sum "$1" | cut -c1-32
	fi
}

# publish TMP DEST: make TMP read-only and rename it to DEST. DEST is keyed by
# content, so when a concurrent job published first its copy is identical and
# ours is discarded.
publish() {
	local tmp="$1" dest="$2"
	chmod -R a-w "$tmp" || die "could not cache $dest"
	if ! mv -T "$tmp" "$dest" 2>/dev/null; then
		[[ -e "$dest" ]] || die "could not cache $dest"
		chmod -R u+w "$tmp" && rm -rf "$tmp"
	fi
}

# freeze SRC DEST: copy SRC to DEST once, read-only; touching DEST marks it in
# use for prune.
freeze() {
	local src="$1" dest="$2"
	if [[ ! -e "$dest" ]]; then
		mkdir -p "$(dirname "$dest")"
		cp -a "$src" "$dest.tmp.$$" || die "could not cache $src"
		publish "$dest.tmp.$$" "$dest"
	fi
	touch -h "$dest" 2>/dev/null || true
}

ensure_image() {
	local tag
	tag="minerva-container-test:$(cat "$TOOLS_DIR"/Dockerfile "$TOOLS_DIR"/*.sh "$TOOLS_DIR"/*.py | sha256sum | cut -c1-12)"
	if ! docker image inspect "$tag" > /dev/null 2>&1; then
		echo "building $tag" >&2
		docker build -q -t "$tag" "$TOOLS_DIR" > /dev/null || die "image build failed"
	fi
	IMAGE="$tag"
}

cmd_run() {
	local rev=HEAD name="" cpus=4 memory=8g timeout_s=1800 out=""
	while (( $# )); do
		case "$1" in
			--rev) rev="$2"; shift 2 ;;
			--name) name="$2"; shift 2 ;;
			--cpus) cpus="$2"; shift 2 ;;
			--memory) memory="$2"; shift 2 ;;
			--timeout) timeout_s="$2"; shift 2 ;;
			--out) out="$2"; shift 2 ;;
			--) shift; break ;;
			-*) die "unknown option $1" ;;
			*) break ;;
		esac
	done
	local suites=("$@")
	(( ${#suites[@]} )) || suites=("${DEFAULT_SUITES[@]}")
	[[ -z "$name" ]] && name="$(date +%Y%m%d-%H%M%S)-$RANDOM"
	[[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || die "job name must match [A-Za-z0-9_.-]+"
	out="${out:-$CACHE/runs/$name}"
	[[ -e "$out" ]] && die "results directory already exists: $out"

	local sha
	sha="$(git -C "$REPO_ROOT" rev-parse --verify "$rev^{commit}")" || die "no such revision: $rev"
	ensure_image

	local snapshot="$CACHE/snapshots/$sha"
	if [[ ! -e "$snapshot" ]]; then
		echo "snapshotting $sha" >&2
		mkdir -p "$snapshot.tmp.$$" \
			&& git -C "$REPO_ROOT" archive "$sha" | tar -x -C "$snapshot.tmp.$$" \
			|| die "git archive failed"
		publish "$snapshot.tmp.$$" "$snapshot"
	fi
	touch -h "$snapshot"

	mkdir -p "$out/logs" || die "cannot create $out"
	local mounts=(-v "$snapshot:/snapshot:ro" -v "$out:/out" -v "$out/natives-paths.txt:/natives/paths.txt:ro")
	: > "$out/natives-paths.txt"
	: > "$out/natives.txt"
	local p h
	for p in "${NATIVE_PATHS[@]}"; do
		if [[ ! -e "$REPO_ROOT/$p" ]]; then
			echo "missing native: $p" >> "$out/natives.txt"
			continue
		fi
		h="$(content_hash "$REPO_ROOT/$p")"
		freeze "$REPO_ROOT/$p" "$CACHE/natives/$h"
		echo "$p" >> "$out/natives-paths.txt"
		echo "$h $p" >> "$out/natives.txt"
		mounts+=(-v "$CACHE/natives/$h:/natives/tree/$p:ro")
	done

	local container="minerva-ct-$name"
	docker create --name "$container" --label "$LABEL=$name" --rm --init \
		--network none --ipc private --cap-drop ALL --security-opt no-new-privileges \
		--user "$(id -u):$(id -g)" \
		--cpus "$cpus" --memory "$memory" --memory-swap "$memory" --pids-limit 4096 --shm-size 1g \
		"${mounts[@]}" "$IMAGE" "${suites[@]}" > /dev/null || die "docker create failed"

	# Record docker's own account of the isolation before anything runs.
	python3 - "$out/run.json" "$sha" "$name" "$IMAGE" "$cpus" "$memory" "$timeout_s" \
		"$(docker image inspect -f '{{.Id}}' "$IMAGE")" "$(docker inspect "$container")" "${suites[@]}" <<'EOF'
import json, sys, time
path, sha, name, image, cpus, memory, timeout_s, image_id, inspect, *suites = sys.argv[1:]
c = json.loads(inspect)[0]
hc = c["HostConfig"]
json.dump({
    "job": name, "revision": sha, "image": image, "image_id": image_id,
    "suites": suites, "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "limits": {"cpus": cpus, "memory": memory, "timeout_s": int(timeout_s),
               "pids_limit": hc.get("PidsLimit")},
    "isolation": {"network_mode": hc.get("NetworkMode"), "pid_mode": hc.get("PidMode") or "private",
                  "ipc_mode": hc.get("IpcMode"), "cap_drop": hc.get("CapDrop"),
                  "mounts": [{"source": m["Source"], "target": m["Destination"], "rw": m["RW"]}
                             for m in c.get("Mounts", [])]},
}, open(path, "w"), indent=2)
EOF

	# The EXIT trap kills the job if this driver is interrupted, so a job never
	# outlives its driver; at the deadline, timeout stops the attached client
	# and the trap kills the container.
	trap 'docker kill '"$container"' > /dev/null 2>&1' EXIT
	trap 'exit 130' INT TERM

	echo "job $name: revision $sha, results in $out" >&2
	timeout "$timeout_s" docker start -a "$container"
	local rc=$?
	if (( rc == 124 )); then
		echo "container-test: deadline ${timeout_s}s reached, killed $container" >&2
		docker kill "$container" > /dev/null 2>&1
	fi
	# A killed job never writes exit_code or results; record docker's status
	# and judge what it left, so its unfinished suites read "not_run".
	[[ -f "$out/exit_code" ]] || echo "$rc" > "$out/exit_code"
	if [[ ! -f "$out/results.json" && -f "$out/tests.txt" ]]; then
		python3 "$TOOLS_DIR/accounting.py" "$out/logs" "$out/tests.txt" "$out/results.json"
	fi
	python3 - "$out/run.json" "$rc" <<'EOF'
import json, sys, time
path, rc = sys.argv[1], int(sys.argv[2])
run = json.load(open(path))
run.update(finished_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), container_exit=rc)
json.dump(run, open(path, "w"), indent=2)
EOF
	echo "job $name: exit $rc — $out/results.json" >&2
	return "$rc"
}

cmd_stop() {
	[[ -n "${1:-}" ]] || die "usage: stop NAME"
	docker kill "$(docker ps -q --filter "label=$LABEL=$1")" 2>/dev/null || die "no running job named $1"
}

cmd_list() {
	docker ps --filter "label=$LABEL" --format '{{.Label "'"$LABEL"'"}}\t{{.Status}}\t{{.Names}}'
}

cmd_prune() {
	local days="${1:-7}"
	[[ -z "$(docker ps -q --filter "label=$LABEL")" ]] || die "jobs are running; prune when idle"
	local d
	for d in snapshots natives runs; do
		[[ -d "$CACHE/$d" ]] || continue
		find "$CACHE/$d" -mindepth 1 -maxdepth 1 -mtime "+$days" -print0 |
			while IFS= read -r -d '' entry; do
				chmod -R u+w "$entry" && rm -rf "$entry" && echo "pruned $entry"
			done
	done
}

case "${1:-}" in
	run) shift; cmd_run "$@" ;;
	stop) shift; cmd_stop "$@" ;;
	list) cmd_list ;;
	prune) shift; cmd_prune "$@" ;;
	*) sed -n '2,19p' "$0"; exit 2 ;;
esac
