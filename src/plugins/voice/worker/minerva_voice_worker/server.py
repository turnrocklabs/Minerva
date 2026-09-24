"""MCP stdio control plane for the Voice Support plugin's detector."""

from __future__ import annotations

import asyncio
import json
import logging
import math
import sys
from pathlib import Path

from .detector import DEFAULT_VAD_SILENCE_MS, VoiceDetector
from .session import AudioSession

PROTOCOL_VERSION = "2025-06-18"
MAX_CONTROL_LINE_CHARS = 64 * 1024
MAX_PENDING_CONTROL_REQUESTS = 32
log = logging.getLogger("minerva_voice_worker")


def _tool(name: str, description: str, properties: dict, required: list[str] | None = None) -> dict:
    return {
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required or [],
            "additionalProperties": False,
        },
    }


TOOLS = [
    _tool("minerva_voice_start", "Load the detector and open an authenticated local audio session.", {}),
    _tool("minerva_voice_status", "Return detector readiness and local audio endpoint metadata.", {}),
    _tool("minerva_voice_reset", "Clear detector state for a new utterance.", {}),
    _tool("minerva_voice_stop", "Close the audio endpoint and release detector state.", {}),
    _tool(
        "minerva_voice_configure",
        "Set wake-word and silence thresholds.",
        {
            "wake_word_threshold": {"type": "number", "exclusiveMinimum": 0, "maximum": 1},
            "vad_silence_ms": {"type": "integer", "minimum": 100, "maximum": 30000},
        },
    ),
]


class VoiceWorker:
    def __init__(self, model_path: Path | None = None, detector_factory=None) -> None:
        self._model_path = model_path or Path(__file__).with_name("models") / "minerva_wakeword.onnx"
        self._wake_word_threshold = 0.90
        self._vad_silence_ms = DEFAULT_VAD_SILENCE_MS
        factory = detector_factory or self._make_detector
        self.session = AudioSession(factory)

    def _make_detector(self) -> VoiceDetector:
        return VoiceDetector(self._model_path, self._wake_word_threshold, self._vad_silence_ms)

    async def dispatch(self, message: dict) -> dict | None:
        request_id = message.get("id")
        method = message.get("method", "")
        if request_id is None:
            return None
        if method == "initialize":
            return self._result(request_id, {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "minerva_voice_worker", "version": "0.1.0"},
            })
        if method == "tools/list":
            return self._result(request_id, {"tools": TOOLS})
        if method != "tools/call":
            return self._error(request_id, -32601, "Method not found")
        params = message.get("params", {})
        try:
            if not isinstance(params, dict):
                raise TypeError("params must be an object")
            value = await self._call_tool(str(params.get("name", "")), params.get("arguments", {}))
            return self._result(request_id, {
                "content": [{"type": "text", "text": json.dumps(value, separators=(",", ":"))}],
                "isError": False,
            })
        except (TypeError, ValueError, OverflowError) as exc:
            return self._error(request_id, -32602, str(exc))
        except Exception:
            log.exception("voice tool failed")
            return self._error(request_id, -32603, "Voice worker operation failed")

    async def _call_tool(self, name: str, arguments: dict) -> dict[str, object]:
        if not isinstance(arguments, dict):
            raise TypeError("arguments must be an object")
        if name == "minerva_voice_start":
            return await self.session.start()
        if name == "minerva_voice_status":
            return self.session.status()
        if name == "minerva_voice_reset":
            await self.session.reset()
            return {"reset": True}
        if name == "minerva_voice_stop":
            await self.session.stop()
            return {"stopped": True}
        if name == "minerva_voice_configure":
            threshold_value = arguments.get("wake_word_threshold", self._wake_word_threshold)
            silence_value = arguments.get("vad_silence_ms", self._vad_silence_ms)
            if isinstance(threshold_value, bool) or not isinstance(threshold_value, (int, float)):
                raise ValueError("wake_word_threshold must be a finite number")
            if isinstance(silence_value, bool) or not isinstance(silence_value, int):
                raise ValueError("vad_silence_ms must be an integer")
            threshold = float(threshold_value)
            silence_ms = silence_value
            if not math.isfinite(threshold) or not 0.0 < threshold <= 1.0 or not 100 <= silence_ms <= 30_000:
                raise ValueError("invalid detector configuration")
            self._wake_word_threshold, self._vad_silence_ms = threshold, silence_ms
            await self.session.configure(threshold, silence_ms)
            return {"configured": True}
        raise ValueError(f"unknown tool: {name}")

    @staticmethod
    def _result(request_id, value: dict) -> dict:
        return {"jsonrpc": "2.0", "id": request_id, "result": value}

    @staticmethod
    def _error(request_id, code: int, message: str) -> dict:
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


async def run() -> None:
    logging.basicConfig(stream=sys.stderr, level=logging.INFO, format="[VoiceWorker] %(levelname)s %(message)s")
    sys.stdout.reconfigure(line_buffering=True)
    worker = VoiceWorker()
    send_lock = asyncio.Lock()
    requests: set[asyncio.Task] = set()

    async def process_line(raw_line: bytes, oversized: bool = False) -> None:
        try:
            if oversized:
                raise ValueError("control message exceeds 64 KiB")
            message = json.loads(raw_line.decode("utf-8"))
            if not isinstance(message, dict):
                raise ValueError("request must be an object")
            response = await worker.dispatch(message)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            response = VoiceWorker._error(None, -32700, str(exc))
        if response is not None:
            async with send_lock:
                print(json.dumps(response, separators=(",", ":")), flush=True)

    while line := await asyncio.to_thread(sys.stdin.buffer.readline, MAX_CONTROL_LINE_CHARS + 1):
        oversized = len(line) > MAX_CONTROL_LINE_CHARS
        original = line
        if oversized and not line.endswith(b"\n"):
            while line and not line.endswith(b"\n"):
                line = await asyncio.to_thread(sys.stdin.buffer.readline, MAX_CONTROL_LINE_CHARS + 1)
        is_stop = False
        parsed = None
        if not oversized:
            try:
                parsed = json.loads(original)
                is_stop = (isinstance(parsed, dict) and parsed.get("method") == "tools/call" and
                           isinstance(parsed.get("params"), dict) and
                           parsed["params"].get("name") == "minerva_voice_stop")
            except (json.JSONDecodeError, UnicodeDecodeError):
                pass
        if len(requests) >= MAX_PENDING_CONTROL_REQUESTS and not is_stop:
            async with send_lock:
                busy_id = parsed.get("id") if isinstance(parsed, dict) else None
                print(json.dumps(VoiceWorker._error(busy_id, -32000, "voice worker busy"), separators=(",", ":")), flush=True)
            continue
        task = asyncio.create_task(process_line(original, oversized))
        requests.add(task)
        task.add_done_callback(requests.discard)
    worker.session.begin_shutdown()
    await worker.session.stop()
    if requests:
        _, pending = await asyncio.wait(requests, timeout=0.25)
    else:
        pending = set()
    for request in pending:
        request.cancel()
    if pending:
        await asyncio.gather(*pending, return_exceptions=True)
