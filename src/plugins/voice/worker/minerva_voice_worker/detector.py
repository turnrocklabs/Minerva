"""The proven Docker detector pipeline, adapted for a supervised sidecar."""

from __future__ import annotations

import time
from pathlib import Path
from collections import deque

import numpy as np
import onnxruntime as ort
from openwakeword.vad import VAD
from openwakeword.utils import AudioFeatures

SAMPLE_RATE = 16_000
OWW_CHUNK_SAMPLES = 1_280
VAD_CHUNK_SAMPLES = 512
ENERGY_THRESHOLD = 250
DEFAULT_VAD_SILENCE_MS = 4_700


class VoiceDetector:
    """Energy gate, packaged Silero VAD, and Minerva's ONNX classifier."""

    def __init__(
        self,
        model_path: Path,
        wake_word_threshold: float = 0.90,
        vad_silence_ms: int = DEFAULT_VAD_SILENCE_MS,
    ) -> None:
        self.model_path = Path(model_path)
        self.threshold = wake_word_threshold
        self.start_time = time.monotonic()
        self._classifier = ort.InferenceSession(
            str(self.model_path), providers=["CPUExecutionProvider"]
        )
        self._classifier_input_name = self._classifier.get_inputs()[0].name
        self._vad_model = VAD()
        # The Docker detector used Model.predict only to advance this shared
        # preprocessor, then ran Minerva's classifier itself. Using that same
        # AudioFeatures implementation avoids loading unrelated classifiers.
        self._features = AudioFeatures(ncpu=1)
        self._initial_feature_buffer = self._features.feature_buffer.copy()
        self._oww_buffer = np.empty(0, dtype=np.int16)
        self._vad_buffer = np.empty(0, dtype=np.int16)
        self._vad_active = False
        self._vad_silence_frames = 0
        self._wake_word_cooldown_until = 0.0
        self.set_config(wake_word_threshold, vad_silence_ms)

    def set_config(self, wake_word_threshold: float, vad_silence_ms: int) -> None:
        if not 0.0 < wake_word_threshold <= 1.0:
            raise ValueError("wake_word_threshold must be in (0, 1]")
        if not 100 <= vad_silence_ms <= 30_000:
            raise ValueError("vad_silence_ms must be between 100 and 30000")
        self.threshold = wake_word_threshold
        frame_ms = VAD_CHUNK_SAMPLES * 1_000 // SAMPLE_RATE
        self._vad_silence_threshold = max(1, vad_silence_ms // frame_ms)

    def reset(self) -> None:
        # AudioFeatures has no reset API in pinned openWakeWord 0.4.0. Reset
        # that implementation's streaming buffers while retaining ONNX sessions.
        self._features.raw_data_buffer = deque(maxlen=SAMPLE_RATE * 10)
        self._features.melspectrogram_buffer = np.ones((76, 32))
        self._features.accumulated_samples = 0
        self._features.feature_buffer = self._initial_feature_buffer.copy()
        self._vad_model.reset_states()
        self._oww_buffer = np.empty(0, dtype=np.int16)
        self._vad_buffer = np.empty(0, dtype=np.int16)
        self._vad_active = False
        self._vad_silence_frames = 0
        self._wake_word_cooldown_until = 0.0

    def process_audio(self, pcm_bytes: bytes) -> list[dict[str, object]]:
        if len(pcm_bytes) % 2:
            raise ValueError("PCM chunk is not aligned to signed 16-bit samples")
        audio = np.frombuffer(pcm_bytes, dtype="<i2")
        self._oww_buffer = np.concatenate((self._oww_buffer, audio))
        self._vad_buffer = np.concatenate((self._vad_buffer, audio))
        events: list[dict[str, object]] = []
        while self._vad_buffer.size >= VAD_CHUNK_SAMPLES:
            chunk = self._vad_buffer[:VAD_CHUNK_SAMPLES]
            self._vad_buffer = self._vad_buffer[VAD_CHUNK_SAMPLES:]
            events.extend(self._process_vad_chunk(chunk))
        while self._oww_buffer.size >= OWW_CHUNK_SAMPLES:
            chunk = self._oww_buffer[:OWW_CHUNK_SAMPLES]
            self._oww_buffer = self._oww_buffer[OWW_CHUNK_SAMPLES:]
            event = self._process_wakeword_chunk(chunk)
            if event is not None:
                events.append(event)
        return events

    def _process_vad_chunk(self, chunk: np.ndarray) -> list[dict[str, object]]:
        events: list[dict[str, object]] = []
        rms = float(np.sqrt(np.mean(chunk.astype(np.float64) ** 2)))
        speech = rms >= ENERGY_THRESHOLD and float(
            self._vad_model.predict(chunk, frame_size=VAD_CHUNK_SAMPLES)
        ) > 0.5
        if speech:
            self._vad_silence_frames = 0
            if not self._vad_active:
                self._vad_active = True
                events.append({"type": "vad_start"})
        elif self._vad_active:
            self._vad_silence_frames += 1
            if self._vad_silence_frames >= self._vad_silence_threshold:
                self._vad_active = False
                events.append({"type": "vad_end"})
        return events

    def _process_wakeword_chunk(self, chunk: np.ndarray) -> dict[str, object] | None:
        if time.monotonic() < self._wake_word_cooldown_until:
            return None
        self._features(chunk)
        features = self._features.feature_buffer
        if not isinstance(features, np.ndarray) or features.shape[0] < 16 or features.shape[1] != 96:
            return None
        classifier_input = features[-16:].flatten().astype(np.float32).reshape(1, -1)
        result = self._classifier.run(None, {self._classifier_input_name: classifier_input})
        confidence = float(result[0].flatten()[0])
        if confidence < self.threshold:
            return None
        self._wake_word_cooldown_until = time.monotonic() + 1.0
        return {"type": "wake_word", "confidence": round(confidence, 3)}

    @property
    def is_vad_active(self) -> bool:
        return self._vad_active
