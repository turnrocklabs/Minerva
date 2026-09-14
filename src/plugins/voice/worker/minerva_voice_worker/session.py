"""Authenticated, bounded loopback audio session for the voice worker."""

from __future__ import annotations

import asyncio
import json
import secrets
import threading
from collections.abc import Callable
from typing import Protocol
from urllib.parse import parse_qs, urlparse

import websockets


async def _run_daemon(function, *args):
    """Run cold model loading without making process shutdown wait for it."""
    loop = asyncio.get_running_loop()
    future = loop.create_future()

    def invoke() -> None:
        def deliver(value=None, error=None) -> None:
            if future.done():
                return
            if error is not None:
                future.set_exception(error)
            else:
                future.set_result(value)

        try:
            value = function(*args)
        except BaseException as exc:
            try:
                loop.call_soon_threadsafe(deliver, None, exc)
            except RuntimeError:
                pass  # The daemon may finish after the worker has exited.
        else:
            try:
                loop.call_soon_threadsafe(deliver, value, None)
            except RuntimeError:
                pass

    threading.Thread(target=invoke, name="voice-model-loader", daemon=True).start()
    return await future


class Detector(Protocol):
    def process_audio(self, pcm_bytes: bytes) -> list[dict[str, object]]: ...
    def reset(self) -> None: ...
    def set_config(self, wake_word_threshold: float, vad_silence_ms: int) -> None: ...


class AudioSession:
    MAX_CHUNK_BYTES = 64 * 1024

    def __init__(self, detector_factory: Callable[[], Detector]) -> None:
        self._detector_factory = detector_factory
        self._detector: Detector | None = None
        self._server = None
        self._client = None
        self._token = ""
        self._detector_lock = asyncio.Lock()
        self._lifecycle_lock = asyncio.Lock()
        self._reset_lock = asyncio.Lock()
        self._generation = 0
        self._start_task: asyncio.Task | None = None
        self._wake_word_threshold = 0.90
        self._vad_silence_ms = 4_700
        self._resetting = False
        self._client_generation = 0
        self._accept_starts = True

    @property
    def ready(self) -> bool:
        return self._server is not None and self._detector is not None

    async def start(self) -> dict[str, object]:
        async with self._lifecycle_lock:
            if not self._accept_starts:
                raise RuntimeError("voice worker is shutting down")
            if self.ready:
                return self.status()
            if self._start_task is None:
                self._generation += 1
                generation = self._generation
                self._start_task = asyncio.create_task(self._start(generation))
            task = self._start_task
        try:
            return await task
        finally:
            async with self._lifecycle_lock:
                if self._start_task is task:
                    self._start_task = None

    async def _start(self, generation: int) -> dict[str, object]:
        detector = await _run_daemon(self._detector_factory)
        await asyncio.to_thread(detector.reset)
        token = secrets.token_urlsafe(32)
        server = await websockets.serve(
            lambda websocket: self._handle_client(websocket, generation), "127.0.0.1", 0,
            max_size=self.MAX_CHUNK_BYTES, max_queue=4,
            ping_interval=20, ping_timeout=10,
        )
        async with self._lifecycle_lock:
            if generation != self._generation:
                server.close()
                await server.wait_closed()
                raise RuntimeError("voice session start was cancelled")
            await asyncio.to_thread(detector.set_config, self._wake_word_threshold, self._vad_silence_ms)
            self._detector = detector
            self._token = token
            self._server = server
            return self.status()

    def status(self) -> dict[str, object]:
        port = 0
        if self._server is not None and self._server.sockets:
            port = int(self._server.sockets[0].getsockname()[1])
        return {
            "ready": self.ready,
            "host": "127.0.0.1",
            "port": port,
            "path": "/audio",
            "token": self._token if self.ready else "",
            "sample_rate": 16_000,
            "channels": 1,
            "sample_format": "s16le",
        }

    async def reset(self) -> None:
        # A socket can already contain PCM/events when reset is requested.
        # Rotate it so the reset boundary cannot leak queued pre-reset work.
        async with self._reset_lock:
            self._resetting = True
            self._client_generation += 1
            client, self._client = self._client, None
            close_task = asyncio.create_task(client.close(code=1012, reason="detector reset")) if client else None
            try:
                await self._reset_detector()
            finally:
                if close_task is not None:
                    await close_task
                self._resetting = False

    async def configure(self, wake_word_threshold: float, vad_silence_ms: int) -> None:
        async with self._lifecycle_lock:
            self._wake_word_threshold = wake_word_threshold
            self._vad_silence_ms = vad_silence_ms
            async with self._detector_lock:
                if self._detector is not None:
                    await asyncio.to_thread(self._detector.set_config, wake_word_threshold, vad_silence_ms)

    async def _reset_detector(self) -> None:
        async with self._detector_lock:
            if self._detector is not None:
                await asyncio.to_thread(self._detector.reset)

    def begin_shutdown(self) -> None:
        self._accept_starts = False

    async def stop(self) -> None:
        # Invalidate admission before yielding to the asynchronous close. A
        # late connection can never attach to a session while it is stopping.
        async with self._lifecycle_lock:
            self._generation += 1
            self._start_task = None
            client, self._client = self._client, None
            server, self._server = self._server, None
            if server is not None:
                server.close()
            self._client_generation += 1
            self._detector = None
            self._token = ""
        if client is not None:
            await client.close(code=1001, reason="session stopped")
        if server is not None:
            await server.wait_closed()

    async def _handle_client(self, websocket, session_generation: int) -> None:
        query = parse_qs(urlparse(websocket.request.path).query)
        supplied = query.get("token", [""])[0]
        if (session_generation != self._generation or self._resetting or
                not self._token or not secrets.compare_digest(supplied, self._token)):
            await websocket.close(code=1008, reason="unauthorized")
            return
        if self._client is not None:
            await websocket.close(code=1013, reason="audio client already connected")
            return
        detector = self._detector
        if detector is None:
            await websocket.close(code=1011, reason="detector unavailable")
            return
        self._client = websocket
        self._client_generation += 1
        client_generation = self._client_generation
        try:
            await self._reset_detector()
            if self._client is not websocket or client_generation != self._client_generation:
                return
            async for message in websocket:
                if not isinstance(message, bytes):
                    await websocket.close(code=1003, reason="binary PCM required")
                    return
                if not message or len(message) > self.MAX_CHUNK_BYTES or len(message) % 2:
                    await websocket.close(code=1009, reason="invalid PCM chunk")
                    return
                async with self._detector_lock:
                    if self._client is not websocket or client_generation != self._client_generation:
                        return
                    events = await asyncio.to_thread(detector.process_audio, message)
                    if self._client is not websocket or client_generation != self._client_generation:
                        continue
                for event in events:
                    if self._client is not websocket or client_generation != self._client_generation:
                        return
                    await websocket.send(json.dumps(event, separators=(",", ":")))
        except websockets.exceptions.ConnectionClosed:
            # Reset and Stop intentionally rotate the socket. The generation
            # checks above already discard work owned by that closed session.
            pass
        finally:
            if self._client is websocket:
                self._client = None
                await self._reset_detector()
