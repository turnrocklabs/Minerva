"""Tiered voice detector: energy gate → VAD → wake word.

Tier 1 (energy gate): skip silent frames. Near-zero CPU cost.
Tier 2 (VAD): Silero VAD detects speech activity. ~2ms/frame.
Tier 3 (wake word): openWakeWord embeddings + custom ONNX classifier. ~5ms/frame.

Only runs expensive tiers when cheaper tiers indicate activity.
"""

import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
import torch

SAMPLE_RATE = 16000
# openWakeWord processes 80ms chunks (1280 samples at 16kHz)
OWW_CHUNK_SAMPLES = 1280
# Silero VAD processes 32ms chunks (512 samples at 16kHz)
VAD_CHUNK_SAMPLES = 512

# Energy gate: RMS below this threshold is considered silence
ENERGY_THRESHOLD = 50  # int16 RMS (~0.15% of full scale)

# VAD settings
VAD_MIN_SILENCE_MS = 300
VAD_SPEECH_PAD_MS = 100


class VoiceDetector:
    """Tiered audio detector for wake word and voice activity."""

    def __init__(self, model_path: str, threshold: float = 0.90):
        self.threshold = threshold
        self.ready = False
        self.start_time = time.time()

        # Tier 2: Silero VAD
        self._vad_model, self._vad_utils = torch.hub.load(
            "snakers4/silero-vad", "silero_vad", trust_repo=True
        )
        (self._get_speech_timestamps, _, _, _, _) = self._vad_utils
        self._vad_state = None
        self._vad_active = False
        self._vad_silence_frames = 0
        self._vad_silence_threshold = int(VAD_MIN_SILENCE_MS / (VAD_CHUNK_SAMPLES / SAMPLE_RATE * 1000))

        # Tier 3: openWakeWord embedding model + custom ONNX classifier
        from openwakeword.model import Model as OWWModel
        self._oww_model = OWWModel()

        # Custom classifier
        self._classifier = ort.InferenceSession(
            model_path,
            providers=["CUDAExecutionProvider", "CPUExecutionProvider"],
        )
        self._classifier_input_name = self._classifier.get_inputs()[0].name

        # Audio buffers
        self._oww_buffer = np.array([], dtype=np.int16)
        self._vad_buffer = np.array([], dtype=np.int16)

        # State
        self._wake_word_cooldown_until = 0.0
        self.ready = True
        print(f"[Detector] Initialized (threshold={threshold})")

    def reset(self):
        """Reset all detector state."""
        self._oww_model.reset()
        self._oww_buffer = np.array([], dtype=np.int16)
        self._vad_buffer = np.array([], dtype=np.int16)
        self._vad_active = False
        self._vad_silence_frames = 0
        self._wake_word_cooldown_until = 0.0
        # Reset VAD iterator state
        self._vad_model.reset_states()

    def process_audio(self, pcm_bytes: bytes) -> list[dict]:
        """Process raw PCM s16le audio. Returns list of events."""
        audio = np.frombuffer(pcm_bytes, dtype=np.int16)
        events = []

        # Accumulate into buffers
        self._oww_buffer = np.concatenate([self._oww_buffer, audio])
        self._vad_buffer = np.concatenate([self._vad_buffer, audio])

        # Process VAD chunks (32ms)
        while len(self._vad_buffer) >= VAD_CHUNK_SAMPLES:
            chunk = self._vad_buffer[:VAD_CHUNK_SAMPLES]
            self._vad_buffer = self._vad_buffer[VAD_CHUNK_SAMPLES:]

            vad_events = self._process_vad_chunk(chunk)
            events.extend(vad_events)

        # Process wake word chunks (80ms)
        while len(self._oww_buffer) >= OWW_CHUNK_SAMPLES:
            chunk = self._oww_buffer[:OWW_CHUNK_SAMPLES]
            self._oww_buffer = self._oww_buffer[OWW_CHUNK_SAMPLES:]

            ww_event = self._process_wakeword_chunk(chunk)
            if ww_event:
                events.append(ww_event)

        return events

    def _process_vad_chunk(self, chunk: np.ndarray) -> list[dict]:
        """Tier 1+2: energy gate then VAD."""
        events = []

        # Tier 1: energy gate
        rms = np.sqrt(np.mean(chunk.astype(np.float64) ** 2))
        if rms < ENERGY_THRESHOLD:
            # Silence — if VAD was active, count silence frames
            if self._vad_active:
                self._vad_silence_frames += 1
                if self._vad_silence_frames >= self._vad_silence_threshold:
                    self._vad_active = False
                    events.append({"type": "vad_end"})
            return events

        # Tier 2: Silero VAD
        audio_float = chunk.astype(np.float32) / 32768.0
        audio_tensor = torch.from_numpy(audio_float)

        speech_prob = self._vad_model(audio_tensor, SAMPLE_RATE).item()

        if speech_prob > 0.5:
            self._vad_silence_frames = 0
            if not self._vad_active:
                self._vad_active = True
                events.append({"type": "vad_start"})
        else:
            if self._vad_active:
                self._vad_silence_frames += 1
                if self._vad_silence_frames >= self._vad_silence_threshold:
                    self._vad_active = False
                    events.append({"type": "vad_end"})

        return events

    def _process_wakeword_chunk(self, chunk: np.ndarray) -> dict | None:
        """Tier 3: wake word detection (only when VAD is active or recently active)."""
        # Cooldown check
        if time.time() < self._wake_word_cooldown_until:
            return None

        # Feed chunk through openWakeWord for embedding extraction
        self._oww_model.predict(chunk)

        # Extract embedding features
        fb = self._oww_model.preprocessor.feature_buffer
        if not isinstance(fb, np.ndarray) or fb.shape[0] < 16 or fb.shape[1] != 96:
            return None

        # Take last 16 frames (1536 dims)
        features = fb[-16:].flatten().astype(np.float32).reshape(1, -1)

        # Run classifier
        result = self._classifier.run(None, {self._classifier_input_name: features})
        confidence = float(result[0].flatten()[0])

        if confidence >= self.threshold:
            # Cooldown: 1 second after detection
            self._wake_word_cooldown_until = time.time() + 1.0
            return {"type": "wake_word", "confidence": round(confidence, 3)}

        return None

    @property
    def is_vad_active(self) -> bool:
        return self._vad_active
