"""Minerva Voice Gateway — local wake word + VAD processing.

Receives PCM audio from Minerva client via WebSocket,
runs tiered detection (energy gate → VAD → wake word),
returns JSON events.

No mic access needed — Minerva captures audio and streams it here.
"""

import asyncio
import json
import os
import time
from pathlib import Path

import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from .detector import VoiceDetector

app = FastAPI(title="Minerva Voice Gateway")

# Singleton detector (loaded once at startup)
_detector: VoiceDetector = None


@app.on_event("startup")
async def startup():
    global _detector
    model_path = os.environ.get(
        "WAKEWORD_MODEL_PATH",
        str(Path(__file__).parent / "minerva_wakeword.onnx"),
    )
    threshold = float(os.environ.get("WAKEWORD_THRESHOLD", "0.90"))
    _detector = VoiceDetector(model_path=model_path, threshold=threshold)
    print(f"[VoiceGateway] Ready (model={model_path}, threshold={threshold})")


@app.get("/health")
async def health():
    return JSONResponse({
        "status": "healthy",
        "detector_ready": _detector is not None and _detector.ready,
        "uptime_seconds": int(time.time() - _detector.start_time) if _detector else 0,
    })


@app.websocket("/audio")
async def audio_ws(ws: WebSocket):
    """Main audio processing WebSocket.

    Client sends: binary PCM s16le 16kHz mono chunks (any size).
    Server sends: JSON events:
      {"type": "wake_word", "confidence": 0.95}
      {"type": "vad_start"}
      {"type": "vad_end"}
    """
    await ws.accept()
    print("[VoiceGateway] Client connected")

    _detector.reset()

    try:
        while True:
            data = await ws.receive_bytes()
            events = _detector.process_audio(data)
            for event in events:
                await ws.send_json(event)
    except WebSocketDisconnect:
        print("[VoiceGateway] Client disconnected")
    except Exception as e:
        print(f"[VoiceGateway] WebSocket error: {e}")


@app.post("/reset")
async def reset():
    """Reset detector state (e.g., after barge-in)."""
    if _detector:
        _detector.reset()
    return JSONResponse({"status": "reset"})
