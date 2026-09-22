#!/usr/bin/env bash
# Run functional suites and a source-tree app smoke in a throwaway container,
# beside (never against) a running Minerva.
#
#   scripts/container-test.sh run [options] [SUITE...]
#   scripts/container-test.sh stop NAME     # kill one run; others keep going
#   scripts/container-test.sh list          # running jobs
#   scripts/container-test.sh prune         # report cache size; reclaiming is disabled
#
# run options:
#   --rev REV       commit to test (default HEAD). Uncommitted edits are NOT
#                   tested — commit (a WIP commit is fine) first.
#   --name NAME     job name (default: generated); container is minerva-ct-NAME
#   --cpus N        CPU limit (default 4)
#   --memory SIZE   memory limit, no swap (default 8g)
#   --timeout SEC   whole-job deadline (default 1800)
#   --import-timeout SEC  per import pass (default 600); a failed or timed-out
#                   import fails the job before any suite runs
#   --out DIR       results directory (default: <cache>/runs/NAME)
# SUITE is a path registered in scripts/run-functional-tests.sh or "app-smoke";
# the default is a small representative set (DEFAULT_SUITES below).
#
# Isolation: the container gets its own PID, network (--network none: only its
# own loopback, so two jobs and the live app can all use port 9315), user
# profile, HOME and Xvfb display. The host checkout is never mounted — the
# revision arrives as a read-only `git archive` snapshot, and the gitignored
# native binaries are built FROM THAT REVISION by container-build/build.py
# (terminal extension, schema helper, agent-relay stage, godot-cef, and the
# pinned sqlite/ffmpeg releases), cached by their inputs and mounted
# read-only. The results directory is the only writable host mount. Caches
# live in ${MINERVA_CT_CACHE:-~/.cache/minerva-container-tests}.
#
# Limits of what a run proves: the voice runtime and host-pdf sidecar are not
# built, so suites needing them fail (never fall back to host copies).
# app-smoke boots the source tree, not a packaged export. A native build
# failure fails the job before any suite runs (stage native-build). --timeout
# bounds the test container only; native builds (build.py) have no deadline
# of their own in this batch.
#
# Results: <out>/run.json (revision, native hashes, image, limits, docker's own
# view of mounts/namespaces), <out>/results.json (per-suite strict verdicts, see
# container-test/accounting.py), <out>/logs/. Exit status is the job's: 0 only
# when every suite passed with at least one assertion and no skips. Stopping a
# job (stop NAME, the deadline, or SIGINT/SIGTERM to this driver) kills its
# container and still writes exit_code, a not-green results.json and a
# finished run.json. SIGKILL of the driver cannot be cleaned up after.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/scripts/container-test"
# Set-but-empty MINERVA_CT_CACHE is refused (validate_cache_root), not defaulted.
if [[ -v MINERVA_CT_CACHE ]]; then
	CACHE="$MINERVA_CT_CACHE"
else
	CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/minerva-container-tests"
fi
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
BUILD=(python3 -B "$REPO_ROOT/scripts/container-build/build.py")

die() { echo "container-test: $*" >&2; exit 2; }

# This script deletes nothing on the host: cache entries are staged in private
# directories created atomically by mktemp -d, published by rename, a race
# loser's identical copy is left in place and reported, and prune only reports.
# Reclaiming disk is a separate, reviewed step. These checks assume nothing else
# mutates the cache concurrently; they are not protection against a hostile
# filesystem (a symlinked ancestor of the root, for one, is not refused).

# validate_cache_root: the same rules as container-build/build.py. $CACHE must
# be a non-empty absolute path that is not a symlink, /, $HOME or above it, or
# this repo or above it. Sets CACHE to the canonical path.
validate_cache_root() {
	local root home lexical="$CACHE"
	[[ "$lexical" == /* ]] || die "MINERVA_CT_CACHE must be an absolute path, got '$CACHE'"
	# Strip trailing slashes first, as pathlib does, so "link/" is tested as "link".
	while [[ "$lexical" == */ && "$lexical" != / ]]; do lexical="${lexical%/}"; done
	[[ -L "$lexical" ]] && die "refusing cache root $lexical: it is a symlink"
	root="$(realpath -m -- "$lexical")"
	home="$(realpath -m -- "$HOME")"
	[[ "$root" == / ]] && die "refusing cache root /"
	case "$home/" in "$root"/*) die "refusing cache root $root: too broad" ;; esac
	case "$REPO_ROOT/" in "$root"/*) die "refusing cache root $root: too broad" ;; esac
	CACHE="$root"
}

# All publishing and integrity checks go through one helper, shared with
# container-build/build.py: a no-clobber rename (renameat2 RENAME_NOREPLACE,
# no fallback) and a tree digest that never follows symlinks.
PUBLISH=(python3 -B "$REPO_ROOT/scripts/container-build/publish.py")

# publish TMP DEST: no-clobber publish of a staged copy. An existing DEST is
# accepted only when it matches TMP exactly (TMP is then kept and reported);
# anything else fails the run with both left in place.
publish() { "${PUBLISH[@]}" publish "$1" "$2" || die "could not publish $2; see the message above"; }

# fail_before_container OUT RC STAGE SHA NAME SUITE...: a job that fails
# before its container exists still leaves exit_code, a not-green
# results.json (the failed stage, every suite not_run) and a run.json naming
# the job, revision and stage. accounting.py exits 1 for "not green" — that
# is expected here and recorded, never allowed to cut the handler short.
fail_before_container() {
	local out="$1" rc="$2" stage="$3" sha="$4" name="$5" acct_rc=0
	shift 5
	printf '%s\n' "$@" > "$out/tests.txt"
	echo "$stage 1" >> "$out/logs/stages.txt"
	echo "$rc" > "$out/exit_code"
	python3 -B "$TOOLS_DIR/accounting.py" "$out/logs" "$out/tests.txt" "$out/results.json" || acct_rc=$?
	python3 -c 'import json, sys, time; json.dump({"job": sys.argv[2], "revision": sys.argv[3],
	    "failed_stage": sys.argv[4], "accounting_exit": int(sys.argv[5]), "container_exit": None,
	    "finished_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, open(sys.argv[1], "w"), indent=2)' \
		"$out/run.json" "$name" "$sha" "$stage" "$acct_rc" || echo "container-test: could not write $out/run.json" >&2
	echo "job $name: $stage failed at $sha — $out/results.json" >&2
	exit "$rc"
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
	local rev=HEAD name="" cpus=4 memory=8g timeout_s=1800 import_timeout=600 out=""
	while (( $# )); do
		case "$1" in
			--rev) rev="$2"; shift 2 ;;
			--name) name="$2"; shift 2 ;;
			--cpus) cpus="$2"; shift 2 ;;
			--memory) memory="$2"; shift 2 ;;
			--timeout) timeout_s="$2"; shift 2 ;;
			--import-timeout) import_timeout="$2"; shift 2 ;;
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

	validate_cache_root
	local sha
	sha="$(git -C "$REPO_ROOT" rev-parse --verify "$rev^{commit}")" || die "no such revision: $rev"
	ensure_image

	local snapshot="$CACHE/snapshots/$sha"
	if [[ -e "$snapshot" || -L "$snapshot" ]]; then
		"${PUBLISH[@]}" check-git "$snapshot" "$REPO_ROOT" "$sha" \
			|| die "cached snapshot $snapshot is not git archive $sha; left as is"
	else
		echo "snapshotting $sha" >&2
		local tmp
		mkdir -p "$CACHE/snapshots" && tmp="$(mktemp -d "$snapshot.tmp.XXXXXX")" \
			&& git -C "$REPO_ROOT" archive "$sha" | tar -x -C "$tmp" \
			|| die "git archive failed"
		"${PUBLISH[@]}" check-git "$tmp" "$REPO_ROOT" "$sha" || die "staged snapshot $tmp does not match $sha"
		publish "$tmp" "$snapshot"
	fi

	mkdir -p "$out/logs" "$out/provenance" || die "cannot create $out"
	# Natives built from this revision (cache hits verified by build.py); a
	# build failure is a failed stage, not a crash.
	echo "building natives for $sha (log: $out/native-build.log)" >&2
	MINERVA_CT_CACHE="$CACHE" "${BUILD[@]}" ensure --rev "$sha" --manifest "$out/natives.json" \
		> "$out/native-build.log" 2>&1 \
		|| fail_before_container "$out" 1 native-build "$sha" "$name" "${suites[@]}"
	# Rows are produced whole or not at all (build.py mount-rows re-verifies
	# every entry first); only a successful, complete file is consumed.
	"${BUILD[@]}" mount-rows --manifest "$out/natives.json" --provenance-dir "$out/provenance" \
		> "$out/native-mounts.tsv" 2>> "$out/native-build.log" \
		|| fail_before_container "$out" 1 native-mounts "$sha" "$name" "${suites[@]}"
	local mounts=(-v "$snapshot:/snapshot:ro" -v "$out:/out" -v "$out/natives-paths.txt:/natives/paths.txt:ro")
	local src target
	while IFS=$'\t' read -r src target; do
		mounts+=(-v "$src:/natives/tree/$target:ro")
		echo "$target" >> "$out/natives-paths.txt"
	done < "$out/native-mounts.tsv"
	[[ -s "$out/natives-paths.txt" ]] || fail_before_container "$out" 1 native-mounts "$sha" "$name" "${suites[@]}"

	local container="minerva-ct-$name"
	docker create --name "$container" --label "$LABEL=$name" --rm --init \
		--network none --ipc private --cap-drop ALL --security-opt no-new-privileges \
		--user "$(id -u):$(id -g)" -e MINERVA_CT_IMPORT_TIMEOUT="$import_timeout" \
		--cpus "$cpus" --memory "$memory" --memory-swap "$memory" --pids-limit 4096 --shm-size 1g \
		"${mounts[@]}" "$IMAGE" "${suites[@]}" > /dev/null || die "docker create failed"

	# Record docker's own account of the isolation before anything runs.
	python3 - "$out/run.json" "$sha" "$name" "$IMAGE" "$cpus" "$memory" "$timeout_s" "$import_timeout" \
		"$(docker image inspect -f '{{.Id}}' "$IMAGE")" "$(docker inspect "$container")" "$out/natives.json" \
		"${suites[@]}" <<'EOF'
import json, sys, time
path, sha, name, image, cpus, memory, timeout_s, import_timeout, image_id, inspect, natives, *suites = sys.argv[1:]
c = json.loads(inspect)[0]
hc = c["HostConfig"]
json.dump({
    "job": name, "revision": sha, "image": image, "image_id": image_id,
    "suites": suites, "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "natives": {"source": "built from this revision by scripts/container-build/build.py",
                "manifest": json.load(open(natives)), "provenance_dir": "provenance/"},
    "limits": {"cpus": cpus, "memory": memory, "timeout_s": int(timeout_s),
               "import_timeout_s": int(import_timeout), "pids_limit": hc.get("PidsLimit")},
    "isolation": {"network_mode": hc.get("NetworkMode"), "pid_mode": hc.get("PidMode") or "private",
                  "ipc_mode": hc.get("IpcMode"), "cap_drop": hc.get("CapDrop"),
                  "mounts": [{"source": m["Source"], "target": m["Destination"], "rw": m["RW"]}
                             for m in c.get("Mounts", [])]},
}, open(path, "w"), indent=2)
EOF

	JOB_OUT="$out" JOB_CONTAINER="$container"
	trap 'finalize_job 130 SIGINT; exit 130' INT
	trap 'finalize_job 143 SIGTERM; exit 143' TERM
	trap 'finalize_job $?' EXIT

	echo "job $name: revision $sha, results in $out" >&2
	# The client runs in the background so a signal to this driver interrupts
	# the wait at once instead of after the job ends.
	timeout "$timeout_s" docker start -a "$container" &
	JOB_CLIENT=$!
	wait "$JOB_CLIENT"
	local rc=$?
	if (( rc == 124 )); then
		echo "container-test: deadline ${timeout_s}s reached, killing $container" >&2
		finalize_job "$rc" deadline
	else
		finalize_job "$rc"
	fi
	return "$rc"
}

JOB_OUT="" JOB_CONTAINER="" JOB_CLIENT="" JOB_FINALIZED=""

# finalize_job RC [REASON]: the one exit path of a run, normal or not. Kills
# the container if it still runs and waits for the client, so nothing writes
# to the results after this; then records RC, judges what the job left (its
# unfinished suites read "not_run") and stamps run.json. A REASON (signal or
# deadline) marks the run interrupted and never green.
finalize_job() {
	local rc="$1" reason="${2:-}"
	[[ -n "$JOB_CONTAINER" && -z "$JOB_FINALIZED" ]] || return 0
	JOB_FINALIZED=1
	docker kill "$JOB_CONTAINER" > /dev/null 2>&1
	[[ -n "$JOB_CLIENT" ]] && wait "$JOB_CLIENT" 2> /dev/null
	if [[ -n "$reason" || ! -f "$JOB_OUT/exit_code" ]]; then
		echo "$rc" > "$JOB_OUT/exit_code"
	fi
	if [[ ! -f "$JOB_OUT/results.json" && -f "$JOB_OUT/tests.txt" ]]; then
		python3 "$TOOLS_DIR/accounting.py" "$JOB_OUT/logs" "$JOB_OUT/tests.txt" "$JOB_OUT/results.json"
	fi
	python3 - "$JOB_OUT" "$rc" "$reason" <<'EOF'
import json, sys, time
from pathlib import Path
out, rc, reason = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
run = json.loads((out / "run.json").read_text())
run.update(finished_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           container_exit=rc, interrupted=reason or None)
(out / "run.json").write_text(json.dumps(run, indent=2))
results_path = out / "results.json"
if reason and results_path.exists():
    results = json.loads(results_path.read_text())
    results.update(green=False, interrupted=reason)
    results_path.write_text(json.dumps(results, indent=2) + "\n")
if not results_path.exists():  # interrupted before the container wrote tests.txt
    results_path.write_text(json.dumps({"green": False, "interrupted": reason or None,
                                        "suites": []}, indent=2) + "\n")
EOF
	echo "job $(basename "$JOB_OUT"): exit $rc${reason:+ ($reason)} — $JOB_OUT/results.json" >&2
}

cmd_stop() {
	[[ -n "${1:-}" ]] || die "usage: stop NAME"
	docker kill "$(docker ps -q --filter "label=$LABEL=$1")" 2>/dev/null || die "no running job named $1"
}

cmd_list() {
	docker ps --filter "label=$LABEL" --format '{{.Label "'"$LABEL"'"}}\t{{.Status}}\t{{.Names}}'
}

# prune: report what the cache holds. Automatic reclamation was withdrawn after
# the delete-safety review (Target 1 01a0c71330d8, comment 2012); it needs its
# own reviewed design. Reclaim by hand, after review, until then.
cmd_prune() {
	validate_cache_root
	echo "container-test: automatic reclamation is disabled pending a reviewed design." >&2
	[[ -d "$CACHE" ]] && du -sh -- "$CACHE"/*/ 2>/dev/null
	exit 2
}

case "${1:-}" in
	run) shift; cmd_run "$@" ;;
	stop) shift; cmd_stop "$@" ;;
	list) cmd_list ;;
	prune) shift; cmd_prune "$@" ;;
	*) sed -n '2,19p' "$0"; exit 2 ;;
esac
