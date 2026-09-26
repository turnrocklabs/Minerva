"""Planned jobs for agent.py: one command at an exact revision of a session's
clone, bounded in CPU, memory and time, with a classified result, and drain.

  agent.py run-job NAME --rev REV --command CMD [--env KEY=VALUE]... [--artifact PATH]...
                   [--cpus N] [--memory SIZE] [--seconds S] [--folder PATH]
  agent.py job-status NAME [JOB]      one job, or every job of the session
  agent.py job-log NAME JOB [--tail BYTES]
  agent.py drain NAME [--wait S] [--lift]

Where a job runs. Each job is its own container of the session's compose
project: the `job` service (docker-compose.yml), which shares the hardened
settings of `dev` (the session's image, host uid, read-only root, no
network, no capabilities) and takes its CPU and memory limits per job. It is
started the way agent.py starts the session's containers (`compose run -d
--rm`), and receives the native build cache the way `dev` does
(natives_manifest). A `docker exec` into the running dev container cannot
bound one command's CPU or memory, and stopping it could reach the agent's
own processes; a container per job can be bounded and stopped whole. The
session itself may be running or stopped.

Revision. The job mounts the session's clone read-only at /src, resolves
--rev there to a commit, and checks that commit out into a fresh shared
clone on the job's /tmp, as container-build/build.py builds a revision
(IN_CONTAINER there). The resolved commit is the job's `revision`.
Submodules are not checked out. Dirty-tree rule: uncommitted changes in the
clone never reach a job, because it runs a fresh checkout of the commit; the
job is not refused, and its result records `source.dirty` (tracked files
modified) and `source.untracked`, so a caller sees that the tree it may have
meant differed from the commit that ran.

Limits. --cpus and --memory (no swap) are the container's cgroup limits.
--seconds bounds the whole job, setup included: the command runs under
`timeout` for the time left, and the container's own `timeout` ends
everything KILL_GRACE_S later. A status call that finds the container still
running after that stops it.

Files. sessions/NAME/jobs/JOB/ holds job.json (the request, written before
the container starts) and result.json (the classification, written once and
never changed), both host-only, natives.json, and in/ (run.sh = IN_JOB,
command.sh, artifacts.txt), mounted read-only at /job. Its out/ is the job's only
writable mount: job.log (everything the job printed), revision,
source-status, artifacts/ (the declared paths, copied after the command ends
within its time), and two end markers: `ended` ("STAGE RC SECONDS", written
by the job script: setup or command) and `exit` ("RC SECONDS", written by
the outer wrapper around it). A command that rewrites these misreports only
itself.

Classification, when the container is gone (--rm removes it on exit):
  ended = setup                               failed (revision or checkout)
  ended = command, rc 0                       succeeded
  ended = command, rc 124/137, time used up   timed_out
  ended = command, any other rc               failed
  exit only, rc 124/137, limit + grace used   timed_out (the outer timeout)
  stopped by drain, neither marker            interrupted
  stopped at the deadline by a status call    timed_out
  none of these                               unknown (ended outside the job)
While the container runs the class is `running`; when docker cannot be
asked it is `unknown` with final false. A final class is written to
result.json once and read back from then on. Only succeeded and failed jobs
claim artifacts complete; a timed_out, interrupted or unknown job claims none.

Drain writes control/drain.json, after which run-job refuses the session
until `drain --lift`. It waits up to --wait seconds for running jobs to end
on their own, then stops each remaining one — only containers this module
started, checked by their job label — and reports every job that was
outstanding with its final class. A drained job is interrupted, never
failed, and nothing is retried: a job runs once, under its own id.
`agent.py stop` stops the session's own containers, not its jobs; drain does.
"""
import os
from pathlib import Path
import re
import secrets
import subprocess
import time

CLASSES = ("succeeded", "failed", "timed_out", "interrupted", "unknown")
JOB_ID = re.compile(r"j[0-9]{8}t[0-9]{6}-[0-9a-f]{6}")
JOB_LABEL = "minerva.agent.job"
ENV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,63}")
RESERVED_ENV = "MINERVA_JOB_"
REVISION = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/@{}^~-]{0,199}")
SHA = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
ARTIFACT = re.compile(r"[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*")
MEMORY = re.compile(r"([1-9][0-9]{0,6})([mg])")
MAX_ARTIFACTS = 32
MAX_COMMAND = 8192
DEFAULT_LIMITS = {"cpus": 2.0, "memory": "4g", "seconds": 1800}
MAX_SECONDS = 86400
# Between the command's deadline and the container's own; also the grace a
# status call allows beyond that before stopping the container itself.
KILL_GRACE_S = 30
STOP_GRACE_S = 10
LOG_TAIL = 32768
MAX_LOG_TAIL = 49152
MAX_LISTED = 50
MAX_DRAIN_WAIT_S = 600
# Exit statuses of `timeout` when it ended the command (TERM, then KILL).
TIMEOUT_RCS = (124, 137)

# The job script, run by bash inside the job container: resolve, check out,
# run the command for the time left, collect artifacts, record how it ended.
IN_JOB = r"""
set -uo pipefail
exec >>/out/job.log 2>&1
ended() { printf '%s %s %s\n' "$1" "$2" "$SECONDS" > /out/ended; exit "$2"; }
echo "== job $MINERVA_JOB_ID: $MINERVA_JOB_REV of $MINERVA_JOB_FOLDER"
sha="$(git --no-optional-locks -C /src rev-parse --verify --end-of-options "$MINERVA_JOB_REV^{commit}")" \
	|| { echo "== revision $MINERVA_JOB_REV not found"; ended setup 90; }
git --no-optional-locks -C /src status --porcelain > /out/source-status || ended setup 91
git clone -q --shared --no-checkout /src /tmp/job/src || ended setup 92
cd /tmp/job/src && git checkout -q --detach "$sha" || ended setup 93
printf '%s\n' "$sha" > /out/revision
echo "== revision: $sha"
echo "== command: $(cat /job/command.sh)"
remaining=$((MINERVA_JOB_SECONDS - SECONDS))
[ "$remaining" -gt 0 ] || ended command 124
timeout -k 10 "$remaining" bash /job/command.sh
rc=$?
echo "== exit $rc after ${SECONDS}s"
if [ "$SECONDS" -lt "$MINERVA_JOB_SECONDS" ]; then
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		if [ -e "$path" ] || [ -L "$path" ]; then
			mkdir -p "/out/artifacts/$(dirname "$path")" && cp -a -- "$path" "/out/artifacts/$path"
		else
			echo "== artifact missing: $path"
		fi
	done < /job/artifacts.txt
	: > /out/artifacts.done
fi
ended command "$rc"
"""

# The container's command: the job script under the outer deadline, then
# the outer exit marker.
OUTER = r"""
timeout -k 10 "$MINERVA_JOB_DEADLINE" bash /job/run.sh
rc=$?
printf '%s %s\n' "$rc" "$SECONDS" > /out/exit
exit "$rc"
"""


# ── where jobs live ──────────────────────────────────────────────────────

def jobs_root(host, name):
    return host.session_dir(name) / "jobs"


def drain_path(host, name):
    return host.session_dir(name) / "control" / "drain.json"


def draining(host, name):
    return host.read_json(drain_path(host, name)).get("draining") is True


def container_name(name, job_id):
    return f"minerva-agent-job-{name}-{job_id}"


def job_dir(host, name, job_id):
    if not JOB_ID.fullmatch(job_id or ""):
        raise host.Refused(f"bad job id {job_id!r}")
    path = jobs_root(host, name) / job_id
    if not (path / "job.json").is_file():
        raise host.Refused(f"session {name} has no job {job_id}")
    return path


# ── the request ──────────────────────────────────────────────────────────

def limits_from(host, cpus, memory, seconds):
    limits = dict(DEFAULT_LIMITS)
    if cpus is not None:
        if not 0.1 <= cpus <= (os.cpu_count() or 1):
            raise host.Refused(f"--cpus must be 0.1-{os.cpu_count() or 1}")
        limits["cpus"] = round(cpus, 2)
    if memory is not None:
        match = MEMORY.fullmatch(memory)
        megabytes = int(match.group(1)) * (1024 if match and match.group(2) == "g" else 1) if match else 0
        if not 64 <= megabytes <= 1024 * 1024:
            raise host.Refused("--memory is a size such as 512m or 4g, 64m-1024g")
        limits["memory"] = memory
    if seconds is not None:
        if not 1 <= seconds <= MAX_SECONDS:
            raise host.Refused(f"--seconds must be 1-{MAX_SECONDS}")
        limits["seconds"] = seconds
    return limits


def env_from(host, pairs):
    env = {}
    for pair in pairs or []:
        key, sep, value = pair.partition("=")
        if not sep or not ENV_NAME.fullmatch(key):
            raise host.Refused(f"--env takes KEY=VALUE with a shell variable name, got {pair!r}")
        if key.startswith(RESERVED_ENV):
            raise host.Refused(f"{RESERVED_ENV}* variables are the job runner's own")
        if "\0" in value:
            raise host.Refused(f"--env {key} holds a NUL byte")
        env[key] = value
    return env


def artifacts_from(host, paths):
    paths = list(dict.fromkeys(paths or []))
    if len(paths) > MAX_ARTIFACTS:
        raise host.Refused(f"a job declares at most {MAX_ARTIFACTS} artifacts")
    for path in paths:
        if not ARTIFACT.fullmatch(path) or ".." in path.split("/") or "." in path.split("/"):
            raise host.Refused(f"artifact {path!r} must be a relative path inside the checkout")
    return paths


def source_clone(host, record, folder):
    """The clone the job's revision comes from: --folder (host or container
    path of a clone folder), else the clone holding the start folder, else
    the first clone."""
    clones = [f for f in record["folders"] if f["kind"] == "clone"]
    if not clones:
        raise host.Refused("the session mounts no git checkout, so a job has no revision to run")
    if folder:
        wanted = os.path.abspath(os.path.expanduser(folder))
        chosen = next((f for f in clones if wanted in (f["path"], f["host"])), None)
        if chosen is None:
            raise host.Refused(f"{folder} is not one of the session's checkout folders")
    else:
        chosen = next((f for f in clones if host.container_path([f], record["start_in"])), clones[0])
    if not Path(chosen["path"]).is_dir():
        raise host.Refused(f"{chosen['path']} does not exist yet: the session's clones are made at its first start")
    return chosen


# ── starting ─────────────────────────────────────────────────────────────

def run_job(host, name, rev, command, env_pairs, artifact_paths, cpus, memory, seconds, folder):
    host.check_layout()
    record = host.load_record(name)
    if record is None:
        raise host.Refused(f"no session {name}")
    host.check_folders(record)
    if not rev or not REVISION.fullmatch(rev):
        raise host.Refused("--rev names a commit: a hash, branch, tag or HEAD-relative name")
    if not command or not command.strip() or len(command) > MAX_COMMAND or "\0" in command:
        raise host.Refused(f"--command is a non-empty shell command of at most {MAX_COMMAND} characters")
    limits = limits_from(host, cpus, memory, seconds)
    env = env_from(host, env_pairs)
    artifacts = artifacts_from(host, artifact_paths)
    source = source_clone(host, record, folder)
    tag = host.image_tag()
    if not host.image_built(tag):
        raise host.Refused(f"image {tag} is not built: run `agent.py build` first")
    with host.session_lock(name, "jobs.lock"):
        if draining(host, name):
            raise host.Refused(f"session {name} is draining: no new jobs until `agent.py drain {name} --lift`")
        host.private_dir(jobs_root(host, name))
        job_id = time.strftime("j%Y%m%dt%H%M%S", time.gmtime()) + "-" + secrets.token_hex(3)
        directory = host.private_dir(jobs_root(host, name) / job_id)
        out = host.private_dir(directory / "out")
        given = host.private_dir(directory / "in")
        for file, text in (("run.sh", IN_JOB), ("command.sh", command + "\n"),
                           ("artifacts.txt", "".join(a + "\n" for a in artifacts))):
            (given / file).write_text(text)
        mounts = host.natives_manifest(directory) + host.bind_mount(source["path"], "/src", True) \
            + host.bind_mount(given, "/job", True) + host.bind_mount(out, "/out")
        job = {"version": 1, "id": job_id, "session": name, "revision_requested": rev,
               "folder": source["path"], "command": command, "env": env, "limits": limits,
               "artifacts": artifacts, "container": container_name(name, job_id), "image": tag,
               "started_at": time.time()}
        host.write_json(directory / "job.json", job)
        variables = {"MINERVA_JOB_ID": job_id, "MINERVA_JOB_REV": rev, "MINERVA_JOB_FOLDER": source["path"],
                     "MINERVA_JOB_SECONDS": str(limits["seconds"]),
                     "MINERVA_JOB_DEADLINE": str(limits["seconds"] + KILL_GRACE_S), **env}
        env_args = [arg for key, value in variables.items() for arg in ("-e", f"{key}={value}")]
        started = subprocess.run(
            host.compose(name, "run", "-d", "--rm", "--name", job["container"],
                         "-l", f"{JOB_LABEL}={job_id}", *env_args, *mounts, "job", "bash", "-c", OUTER),
            env={**host.compose_env(), "MINERVA_JOB_CPUS": str(limits["cpus"]),
                 "MINERVA_JOB_MEMORY": limits["memory"]},
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if started.returncode != 0:
            detail = (started.stderr or "").strip()[-400:]
            finish(host, directory, job, "failed", f"the job container did not start: {detail}")
            raise host.Refused(f"job {job_id} did not start: {detail or 'docker compose run failed'}")
    return {"ok": True, "id": name, "job": describe(host, name, job_id),
            "message": f"job {job_id} running {command!r} at {rev} "
                       f"({limits['cpus']} CPUs, {limits['memory']}, {limits['seconds']} s)"}


# ── classifying ──────────────────────────────────────────────────────────

def _read_ints(path, count):
    """The first `count` integers of a marker file, or None when it is
    missing or not that shape; a leading word is returned as is."""
    try:
        words = path.read_text()[:200].split()
    except (OSError, UnicodeDecodeError):
        return None
    head = [] if not words or words[0].lstrip("-").isdigit() else [words.pop(0)]
    if len(words) < count or not all(w.lstrip("-").isdigit() for w in words[:count]):
        return None
    return head + [int(w) for w in words[:count]]


def classify(job, out):
    """(class, detail, exit_code, elapsed) for a job whose container is gone."""
    seconds = job["limits"]["seconds"]
    ended = _read_ints(out / "ended", 2)
    if ended and len(ended) == 3 and ended[0] in ("setup", "command"):
        stage, rc, elapsed = ended
        if stage == "setup":
            return "failed", f"setup failed (exit {rc}): the revision or its checkout; see the log", rc, elapsed
        if rc == 0:
            return "succeeded", "the command exited 0", rc, elapsed
        if rc in TIMEOUT_RCS and elapsed >= seconds:
            return "timed_out", f"the command was stopped at its {seconds} s limit", rc, elapsed
        return "failed", f"the command exited {rc}" + (" (killed: out of memory at the limit, or a signal)"
                                                     if rc == 137 else ""), rc, elapsed
    outer = _read_ints(out / "exit", 2)
    if outer and len(outer) == 2 and outer[0] in TIMEOUT_RCS and outer[1] >= seconds + KILL_GRACE_S:
        return "timed_out", f"the job was stopped {KILL_GRACE_S} s after its {seconds} s limit", outer[0], outer[1]
    if job.get("drained_at"):
        return "interrupted", "drain stopped the job before it ended; it was not retried", None, None
    if job.get("deadline_stop_at"):
        return "timed_out", "the job outlived its deadline and was stopped", None, None
    return "unknown", "the job's container ended without recording how (stopped outside the job?)", \
        outer[0] if outer and len(outer) == 2 else None, outer[1] if outer and len(outer) == 2 else None


def _source(out):
    try:
        lines = (out / "source-status").read_text(errors="replace").splitlines()
    except OSError:
        return {"known": False, "dirty": None, "modified": None, "untracked": None}
    untracked = sum(1 for line in lines if line.startswith("??"))
    return {"known": True, "dirty": len(lines) > untracked, "modified": len(lines) - untracked,
            "untracked": untracked}


def _artifacts(job, out, cls):
    """Each declared artifact with where it was copied and whether it is
    claimed complete: only for succeeded or failed jobs whose collection
    finished, and never through a symlink."""
    collected = cls in ("succeeded", "failed") and (out / "artifacts.done").is_file()
    root = out / "artifacts"
    listed = []
    for path in job["artifacts"]:
        target = root / path
        present = os.path.lexists(target) and os.path.realpath(target) == str(target) \
            and (target.is_file() or target.is_dir())
        listed.append({"path": path, "host_path": str(target), "present": present,
                       "complete": collected and present})
    return listed


def finish(host, directory, job, cls, detail, exit_code=None, elapsed=None):
    """Write result.json once; an existing one is kept and returned."""
    existing = host.read_json(directory / "result.json")
    if existing.get("class") in CLASSES:
        return existing
    out = directory / "out"
    try:
        revision = (out / "revision").read_text()[:100].strip()
    except OSError:
        revision = ""
    result = {"class": cls, "detail": detail, "exit_code": exit_code, "elapsed_s": elapsed,
              "revision": revision if SHA.fullmatch(revision) else "",
              "revision_requested": job["revision_requested"], "source": {"folder": job["folder"], **_source(out)},
              "artifacts": _artifacts(job, out, cls), "finished_at": time.time()}
    host.write_json(directory / "result.json", result)
    return result


def owned(host, job):
    """True when a container of the job's name exists and carries this job's label."""
    probe = subprocess.run(["docker", "inspect", "-f", f'{{{{index .Config.Labels "{JOB_LABEL}"}}}}',
                            job["container"]], capture_output=True, text=True)
    return probe.returncode == 0 and probe.stdout.strip() == job["id"]


def stop_owned(host, directory, job, mark):
    """Record `mark` on the job, then stop its container if it is ours."""
    job[mark] = time.time()
    host.write_json(directory / "job.json", job)
    if owned(host, job):
        subprocess.run(["docker", "stop", "-t", str(STOP_GRACE_S), job["container"]], capture_output=True)


def reconcile(host, name, job_id):
    """The job's current answer, finishing it (result.json) once its
    container is gone. Holds the session's jobs lock."""
    with host.session_lock(name, "jobs.lock"):
        directory = job_dir(host, name, job_id)
        job = host.read_json(directory / "job.json")
        result = host.read_json(directory / "result.json")
        if result.get("class") in CLASSES:
            return job, dict(result, final=True)
        state = host.docker_state(job["container"])
        if state == "unknown":
            return job, {"class": "unknown", "final": False, "detail": "docker cannot be asked"}
        deadline = job["started_at"] + job["limits"]["seconds"] + 2 * KILL_GRACE_S
        if state == "running" and time.time() > deadline:
            stop_owned(host, directory, job, "deadline_stop_at")
            state = host.docker_state(job["container"])
        if state == "running":
            return job, {"class": "running", "final": False,
                         "elapsed_s": int(time.time() - job["started_at"]),
                         "detail": f"running; limit {job['limits']['seconds']} s"}
        cls, detail, rc, elapsed = classify(job, directory / "out")
        return job, dict(finish(host, directory, job, cls, detail, rc, elapsed), final=True)


def describe(host, name, job_id):
    job, result = reconcile(host, name, job_id)
    return {"job": job_id, "class": result["class"], "final": result["final"],
            "detail": result.get("detail", ""), "revision_requested": job["revision_requested"],
            "revision": result.get("revision", ""), "command": job["command"], "limits": job["limits"],
            "started_at": job["started_at"], "result": result,
            "log": str(job_dir(host, name, job_id) / "out" / "job.log")}


def job_ids(host, name):
    root = jobs_root(host, name)
    ids = [p.name for p in root.iterdir() if JOB_ID.fullmatch(p.name) and (p / "job.json").is_file()] \
        if root.is_dir() else []
    return sorted(ids, reverse=True)


# ── commands ─────────────────────────────────────────────────────────────

def job_status(host, name, job_id):
    host.check_layout()
    if host.load_record(name) is None:
        raise host.Refused(f"no session {name}")
    if job_id:
        described = describe(host, name, job_id)
        return {"ok": True, "id": name, "draining": draining(host, name), **described,
                "message": f"{job_id} {described['class']}: {described['detail']}"}
    jobs = [describe(host, name, j) for j in job_ids(host, name)[:MAX_LISTED]]
    for job in jobs:
        job.pop("result")
    return {"ok": True, "id": name, "draining": draining(host, name), "jobs": jobs,
            "message": "\n".join(f"{j['job']} {j['class']:11} {j['command']}" for j in jobs) or "no jobs"}


def job_log(host, name, job_id, tail):
    host.check_layout()
    tail = LOG_TAIL if tail is None else tail
    if not 1 <= tail <= MAX_LOG_TAIL:
        raise host.Refused(f"--tail must be 1-{MAX_LOG_TAIL} bytes")
    described = describe(host, name, job_id)
    path = job_dir(host, name, job_id) / "out" / "job.log"
    try:
        with open(path, "rb") as f:
            size = f.seek(0, os.SEEK_END)
            f.seek(max(0, size - tail))
            text = f.read(tail).decode("utf-8", errors="replace")
    except OSError:
        size, text = 0, ""
    return {"ok": True, "id": name, "job": job_id, "class": described["class"], "final": described["final"],
            "size": size, "truncated": size > tail, "log": text, "path": str(path), "message": text}


def drain(host, name, wait_s, lift):
    host.check_layout()
    if host.load_record(name) is None:
        raise host.Refused(f"no session {name}")
    control = host.private_dir(host.session_dir(name) / "control")
    with host.session_lock(name, "jobs.lock"):
        host.write_json(control / "drain.json", {"draining": not lift, "at": time.time()})
    if lift:
        return {"ok": True, "id": name, "draining": False, "jobs": [],
                "message": f"session {name} takes new jobs again"}
    wait_s = 0 if wait_s is None else wait_s
    if not 0 <= wait_s <= MAX_DRAIN_WAIT_S:
        raise host.Refused(f"--wait must be 0-{MAX_DRAIN_WAIT_S} seconds")
    outstanding = [j for j in job_ids(host, name) if not reconcile(host, name, j)[1]["final"]]
    deadline = time.monotonic() + wait_s
    running = list(outstanding)
    while running and time.monotonic() < deadline:
        time.sleep(1)
        running = [j for j in running if not reconcile(host, name, j)[1]["final"]]
    for job_id in running:
        with host.session_lock(name, "jobs.lock"):
            directory = job_dir(host, name, job_id)
            job = host.read_json(directory / "job.json")
            if not host.read_json(directory / "result.json").get("class"):
                stop_owned(host, directory, job, "drained_at")
    jobs = []
    for job_id in outstanding:
        described = describe(host, name, job_id)
        described.pop("result")
        jobs.append(described)
    return {"ok": True, "id": name, "draining": True, "jobs": jobs,
            "message": f"session {name} is draining; " + (", ".join(f"{j['job']} {j['class']}" for j in jobs)
                                                         or "no job was running")}
