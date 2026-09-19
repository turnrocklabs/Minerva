#!/usr/bin/env python3
"""Drive a TUI harness through a PTY, recording byte-true output plus a timeline.

Usage: drive.py <outdir> <plan.json>

plan.json = {"cmd": [...], "cwd": "...", "cols": 120, "rows": 40, "env": {...},
             "steps": [ {...}, ... ]}

step kinds:
  {"wait_ms": 3000}
  {"wait_for": "regex", "timeout_ms": 60000}      # regex over decoded tail
  {"wait_quiet_ms": 1500, "timeout_ms": 60000}    # no bytes for N ms
  {"send": "text"}                                # \r, \x1b etc honoured
  {"send_slow": "text", "per_char_ms": 25}        # typed char by char
  {"mark": "name"}

Outputs in outdir: raw.tty (all master bytes), events.jsonl
  each event: {t_ms, off (byte offset into raw.tty at that moment), kind, detail}
"""
import json, os, pty, re, select, signal, sys, time, fcntl, termios, struct

def main():
    outdir, planpath = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    plan = json.load(open(planpath))
    cols = plan.get("cols", 120); rows = plan.get("rows", 40)

    raw = open(os.path.join(outdir, "raw.tty"), "wb")
    ev = open(os.path.join(outdir, "events.jsonl"), "w")
    rd = open(os.path.join(outdir, "reads.jsonl"), "w")
    t0 = time.time()
    state = {"off": 0, "tail": b""}

    def log(kind, detail=None):
        ev.write(json.dumps({"t_ms": round((time.time()-t0)*1000),
                             "off": state["off"], "kind": kind,
                             "detail": detail}) + "\n")
        ev.flush()

    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = str(cols); env["LINES"] = str(rows)
        for pref in plan.get("env_unset_prefixes", []):
            for k in [k for k in env if k.startswith(pref)]:
                env.pop(k)
        env.update(plan.get("env", {}))
        os.chdir(plan.get("cwd", os.getcwd()))
        os.execvpe(plan["cmd"][0], plan["cmd"], env)
        os._exit(127)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    dead = [False]
    def pump(deadline):
        """Read until deadline (absolute time). Returns when deadline hit."""
        while True:
            remain = deadline - time.time()
            if remain <= 0:
                return
            try:
                r, _, _ = select.select([fd], [], [], min(remain, 0.05))
            except (OSError, ValueError):
                dead[0] = True; return
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    dead[0] = True; return
                if not data:
                    dead[0] = True; return
                raw.write(data); raw.flush()
                state["off"] += len(data)
                rd.write(json.dumps({"t_ms": round((time.time()-t0)*1000),
                                     "off": state["off"]}) + "\n")
                state["tail"] = (state["tail"] + data)[-200000:]

    def last_byte_time():
        return state.get("lb", t0)

    log("start", {"cmd": plan["cmd"], "cols": cols, "rows": rows})
    try:
        for step in plan["steps"]:
            if dead[0]:
                log("child_gone"); break
            if "mark" in step:
                log("mark", step["mark"])
            elif "wait_ms" in step:
                log("wait_ms_begin", step["wait_ms"])
                pump(time.time() + step["wait_ms"]/1000.0)
                log("wait_ms_end", step["wait_ms"])
            elif "wait_for" in step:
                pat = re.compile(step["wait_for"])
                to = step.get("timeout_ms", 60000)/1000.0
                end = time.time() + to
                log("wait_for_begin", step["wait_for"])
                hit = False
                while time.time() < end and not dead[0]:
                    pump(time.time() + 0.1)
                    txt = state["tail"].decode("utf-8", "replace")
                    if pat.search(txt):
                        hit = True; break
                log("wait_for_end", {"pat": step["wait_for"], "hit": hit})
            elif "wait_quiet_ms" in step:
                q = step["wait_quiet_ms"]/1000.0
                to = step.get("timeout_ms", 60000)/1000.0
                end = time.time() + to
                log("wait_quiet_begin", step["wait_quiet_ms"])
                last = state["off"]; lastchange = time.time()
                while time.time() < end and not dead[0]:
                    pump(time.time() + 0.05)
                    if state["off"] != last:
                        last = state["off"]; lastchange = time.time()
                    elif time.time() - lastchange >= q:
                        break
                log("wait_quiet_end", None)
            elif "send" in step:
                b = step["send"].encode("utf-8")
                log("send", step["send"])
                os.write(fd, b)
            elif "send_slow" in step:
                log("send_slow_begin", step["send_slow"])
                per = step.get("per_char_ms", 25)/1000.0
                for ch in step["send_slow"]:
                    os.write(fd, ch.encode("utf-8"))
                    pump(time.time() + per)
                log("send_slow_end", step["send_slow"])
            else:
                log("unknown_step", step)
        log("plan_done")
    finally:
        pump(time.time() + 0.3)
        log("end")
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass
        raw.close(); ev.close(); rd.close()

main()
