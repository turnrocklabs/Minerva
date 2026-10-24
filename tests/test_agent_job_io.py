"""Real child pipes and retained dummy evidence; no account credentials."""
import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.parse import quote, quote_plus

AGENT = Path(__file__).resolve().parents[1] / "scripts/agent-container"
sys.path.insert(0, str(AGENT))
import job_io


class JobIOTest(unittest.TestCase):
    def test_real_child_output_is_filtered_and_exit_status_survives(self) -> None:
        scratch = Path(tempfile.mkdtemp(prefix="agent-job-io-"))
        canary = "dummy-private-canary-5721"
        program = scratch / "child.py"
        program.write_text("import os,sys,time\nv=os.environ['DUMMY_JOB_PRIVATE'].encode()\n"
                           "os.write(1,b'before '+v[:7]);time.sleep(.05)\n"
                           "os.write(1,v[7:]+b' after\\n');os.write(2,v+b'\\n');sys.exit(7)\n")
        script = scratch / "run.sh"
        script.write_text(f"{sys.executable} {program}\n")
        driver = scratch / "driver.py"
        driver.write_text(f"import sys\nfrom pathlib import Path\nsys.path.insert(0,{str(AGENT)!r})\n"
                          "import job_io\nraise SystemExit(job_io.run(Path(sys.argv[1]),Path(sys.argv[2])))\n")
        result = subprocess.run([sys.executable, str(driver), str(scratch), str(script)],
                                check=False,
                                env={**os.environ, "DUMMY_JOB_PRIVATE": canary,
                                     "MINERVA_JOB_ENV_FROM": "DUMMY_JOB_PRIVATE",
                                     "MINERVA_JOB_DEADLINE": "5", "MINERVA_JOB_NETWORK": "none"},
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual((scratch / "job.log").read_text(),
                         "before [REDACTED] after\n[REDACTED]\n")
        self.assertEqual((scratch / "exit").read_text().split()[0], "7")
        redactor = job_io.Redactor([b"abcdef"])
        filtered = redactor.feed(b"xxabc") + redactor.feed(b"defyy") + redactor.feed(b"", final=True)
        self.assertEqual(filtered, b"xx[REDACTED]yy")

        # A child retaining the pipe after its parent exits cannot outlive
        # the job's output deadline or turn a timeout into a successful receipt.
        timed = scratch / "timed"
        timed.mkdir()
        program.write_text("import subprocess\nsubprocess.Popen(['sleep','30'])\n")
        result = subprocess.run([sys.executable, str(driver), str(timed), str(script)],
                                check=False, env={**os.environ, "MINERVA_JOB_DEADLINE": "1",
                                                  "MINERVA_JOB_NETWORK": "none",
                                                  "MINERVA_JOB_ENV_FROM": ""},
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual((timed / "ended").read_text().split()[:2], ["command", "124"])

    def test_evidence_refuses_literal_escaped_and_linked_private_content(self) -> None:
        scratch = Path(tempfile.mkdtemp(prefix="agent-evidence-"))
        safe = scratch / "safe.json"
        safe.write_text('{"status":"completed"}\n')
        job_io.check_artifact(safe, [b"dummy-private"])
        bad = scratch / "bad.log"
        bad.write_bytes(b"x" * 65533 + b"dummy-private")
        with self.assertRaises(ValueError):
            job_io.check_artifact(bad, [b"dummy-private"])
        linked = scratch / "link"
        linked.symlink_to(safe)
        with self.assertRaises(ValueError):
            job_io.check_artifact(linked, [])
        encoded = scratch / "encoded.json"
        encoded.write_text('{"password":"dummy\\\"private"}')
        with self.assertRaises(ValueError):
            job_io.check_artifact(encoded, [b'dummy\\"private'])
        named = scratch / "dummy-private.txt"
        named.write_text("safe content")
        with self.assertRaises(ValueError):
            job_io.check_artifact(named, [b"dummy-private"])

        # The final retained copy, including direct /out writes and a log
        # overwritten by the command, is authoritative after all writers exit.
        out = scratch / "out"
        out.mkdir()
        user, password = 'dummy user/+', 'dummy"private +/☃'
        variants = [user.encode(), password.encode(), json.dumps(password)[1:-1].encode(),
                    quote(password).encode(), quote(password, safe="").encode(), quote_plus(password).encode(),
                    base64.b64encode(f"{user}:{password}".encode())]
        (out / "job.log").write_bytes(b"\n".join(variants))
        (out / "artifacts").mkdir()
        (out / "artifacts/safe.json").write_text("completed")
        for index, value in enumerate(variants):
            (out / f"direct-{index}").write_bytes(b"x" * 65533 + value)
        (out / "artifacts/raced-copy").write_text(password)
        (out / "link").symlink_to(safe)
        (out / user.replace("/", "_")).write_text("safe name content")
        report = job_io.finalize_output(out, job_io.redaction_values([user, password]), scratch / "quarantine")
        self.assertTrue(report["scanned"])
        self.assertEqual(report["refused"], len(variants) + 2)
        self.assertEqual((out / "job.log").read_bytes(), b"\n".join([b"[REDACTED]"] * len(variants)))
        self.assertEqual((out / "artifacts/safe.json").read_text(), "completed")
        for candidate in out.rglob("*"):
            if candidate.is_file():
                job_io.check_artifact(candidate, job_io.redaction_values([user, password]))


if __name__ == "__main__":
    unittest.main()
