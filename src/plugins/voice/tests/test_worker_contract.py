"""Portable worker contract exercised with the bundled runtime."""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import threading
import time
import unittest

import websockets

from minerva_voice_worker.server import VoiceWorker


class FakeDetector:
    def __init__(self) -> None:
        self.reset_count = 0
        self.config = (0.9, 4_700)

    def reset(self) -> None:
        self.reset_count += 1

    def set_config(self, threshold: float, silence_ms: int) -> None:
        self.config = (threshold, silence_ms)

    def process_audio(self, pcm: bytes) -> list[dict[str, object]]:
        return [{"type": "vad_start", "samples": len(pcm) // 2}]


class DelayedDetector(FakeDetector):
    def __init__(self) -> None:
        super().__init__()
        self.inference_entered = threading.Event()
        self.inference_release = threading.Event()

    def process_audio(self, pcm: bytes) -> list[dict[str, object]]:
        self.inference_entered.set()
        self.inference_release.wait(2)
        return super().process_audio(pcm)


class WorkerContractTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.detector = FakeDetector()
        self.worker = VoiceWorker(detector_factory=lambda: self.detector)

    async def asyncTearDown(self) -> None:
        await self.worker.session.stop()

    async def call(self, name: str, arguments: dict | None = None) -> dict:
        response = await self.worker.dispatch({
            "jsonrpc": "2.0", "id": name, "method": "tools/call",
            "params": {"name": name, "arguments": arguments or {}},
        })
        self.assertIsNotNone(response)
        self.assertNotIn("error", response)
        return json.loads(response["result"]["content"][0]["text"])

    async def test_readiness_auth_audio_reset_and_stop_are_distinct(self) -> None:
        initialize = await self.worker.dispatch({"jsonrpc": "2.0", "id": 1, "method": "initialize"})
        self.assertEqual(initialize["result"]["protocolVersion"], "2025-06-18")
        self.assertFalse(self.worker.session.ready)

        endpoint = await self.call("minerva_voice_start")
        self.assertTrue(endpoint["ready"])
        self.assertEqual((endpoint["sample_rate"], endpoint["channels"], endpoint["sample_format"]), (16_000, 1, "s16le"))
        base = f"ws://127.0.0.1:{endpoint['port']}/audio"
        unauthorized = await websockets.connect(base + "?token=wrong")
        await unauthorized.wait_closed()
        self.assertEqual(unauthorized.close_code, 1008)

        async with websockets.connect(base + "?token=" + endpoint["token"]) as socket:
            await socket.send(b"\x01\x00" * 512)
            self.assertEqual(json.loads(await socket.recv()), {"type": "vad_start", "samples": 512})
            second = await websockets.connect(base + "?token=" + endpoint["token"])
            await second.wait_closed()
            self.assertEqual(second.close_code, 1013)
            await self.call("minerva_voice_reset")
            await socket.wait_closed()
            self.assertEqual(socket.close_code, 1012)

        # The token remains valid, but a fresh connection starts from reset
        # detector state and cannot receive events queued on the old socket.
        async with websockets.connect(base + "?token=" + endpoint["token"]) as replacement:
            await replacement.send(b"\x02\x00" * 512)
            self.assertEqual(json.loads(await replacement.recv())["samples"], 512)
        self.assertGreaterEqual(self.detector.reset_count, 3)
        await self.call("minerva_voice_stop")
        self.assertFalse(self.worker.session.ready)
        self.assertEqual(self.worker.session.status()["token"], "")

    async def test_configuration_and_pcm_bounds_fail_closed(self) -> None:
        configured = await self.call("minerva_voice_configure", {"wake_word_threshold": 0.82, "vad_silence_ms": 900})
        self.assertTrue(configured["configured"])
        endpoint = await self.call("minerva_voice_start")
        self.assertEqual(self.detector.config, (0.82, 900))
        uri = f"ws://127.0.0.1:{endpoint['port']}/audio?token={endpoint['token']}"
        async with websockets.connect(uri) as socket:
            await socket.send(b"\x00")
            await socket.wait_closed()
            self.assertEqual(socket.close_code, 1009)

        bad = await self.worker.dispatch({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "minerva_voice_configure", "arguments": {"vad_silence_ms": 0}},
        })
        self.assertEqual(bad["error"]["code"], -32602)

    async def test_stop_during_cold_start_prevents_late_endpoint_publication(self) -> None:
        entered, release = threading.Event(), threading.Event()

        def delayed_factory():
            entered.set()
            release.wait(5)
            return self.detector

        worker = VoiceWorker(detector_factory=delayed_factory)
        start = asyncio.create_task(worker.session.start())
        self.assertTrue(await asyncio.to_thread(entered.wait, 1))
        await asyncio.wait_for(worker.session.stop(), 0.2)
        self.assertFalse(worker.session.ready)
        release.set()
        with self.assertRaises(RuntimeError):
            await start
        self.assertFalse(worker.session.ready)

    async def test_reset_discards_delayed_old_events_before_reconnect(self) -> None:
        detector = DelayedDetector()
        worker = VoiceWorker(detector_factory=lambda: detector)
        endpoint = json.loads((await worker.dispatch({
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "minerva_voice_start", "arguments": {}},
        }))["result"]["content"][0]["text"])
        uri = f"ws://127.0.0.1:{endpoint['port']}/audio?token={endpoint['token']}"
        old_socket = await websockets.connect(uri)
        await old_socket.send(b"\x01\x00" * 512)
        self.assertTrue(await asyncio.to_thread(detector.inference_entered.wait, 1))
        reset = asyncio.create_task(worker.session.reset())
        await asyncio.sleep(0)
        detector.inference_release.set()
        await reset
        await old_socket.wait_closed()
        self.assertEqual(old_socket.close_code, 1012)

        async with websockets.connect(uri) as replacement:
            await replacement.send(b"\x02\x00" * 512)
            self.assertEqual(json.loads(await replacement.recv())["samples"], 512)
        await worker.session.stop()

    async def test_stdio_malformed_request_recovers_and_eof_exits(self) -> None:
        initialize = json.dumps({"jsonrpc": "2.0", "id": 7, "method": "initialize"})
        environment = dict(os.environ)
        environment["PYTHONNOUSERSITE"] = "1"
        process = subprocess.Popen(
            [sys.executable, "-B", "-I", "-m", "minerva_voice_worker"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=environment,
        )
        started = time.monotonic()
        phase = "startup/recovery"
        try:
            assert process.stdin is not None
            assert process.stdout is not None
            request_text = ("x" * (64 * 1024 + 1)) + initialize + "\n" + initialize + "\n"

            def write_requests() -> None:
                process.stdin.write(request_text)
                process.stdin.flush()

            # Bound process startup, imports, request delivery, and recovery as
            # one phase. EOF shutdown gets its own tighter deadline below.
            async with asyncio.timeout(120):
                await asyncio.to_thread(write_requests)
                lines = [
                    await asyncio.to_thread(process.stdout.readline),
                    await asyncio.to_thread(process.stdout.readline),
                ]
            replies = [json.loads(line) for line in lines]
            self.assertEqual({reply.get("id") for reply in replies}, {None, 7})
            self.assertTrue(all(line.startswith("{") for line in lines))
            print(f"stdio startup/recovery completed in {time.monotonic() - started:.3f}s")

            phase = "EOF shutdown"
            started = time.monotonic()
            process.stdin.close()
            return_code = await asyncio.wait_for(asyncio.to_thread(process.wait), 5)
            stderr = process.stderr.read() if process.stderr is not None else ""
            self.assertEqual(return_code, 0, stderr)
            self.assertEqual(process.stdout.read(), "", "worker emitted unexpected extra stdout")
            print(f"stdio EOF shutdown completed in {time.monotonic() - started:.3f}s")
        except (asyncio.TimeoutError, json.JSONDecodeError) as error:
            if process.poll() is None:
                process.kill()
                await asyncio.to_thread(process.wait)
            stderr = process.stderr.read() if process.stderr is not None else ""
            self.fail(f"stdio worker {phase} failed after {time.monotonic() - started:.3f}s: {error!r}\n{stderr}")
        finally:
            if process.poll() is None:
                process.kill()
                await asyncio.to_thread(process.wait)
            for pipe in (process.stdin, process.stdout, process.stderr):
                if pipe is not None and not pipe.closed:
                    pipe.close()

        bad_params = await self.worker.dispatch({
            "jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": [],
        })
        self.assertEqual(bad_params["error"]["code"], -32602)


if __name__ == "__main__":
    unittest.main()
