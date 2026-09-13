"""Real packaged-model contract for gateway startup and VAD state reset."""

import socket
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

from app.detector import VAD_CHUNK_SAMPLES, VoiceDetector


class DetectorOfflineTest(unittest.TestCase):
    def test_packaged_vad_starts_offline_and_accepts_nonzero_pcm(self):
        """Exercise model loading and inference shape, not speech accuracy."""

        def refuse_network(*_args, **_kwargs):
            raise AssertionError("detector startup attempted network access")

        model_path = Path(__file__).parents[1] / "app" / "minerva_wakeword.onnx"
        with patch.object(socket.socket, "connect", refuse_network):
            detector = VoiceDetector(str(model_path))

        # Alternating nonzero PCM clears the energy gate and reaches the real VAD.
        chunk = np.tile(np.array([1200, -1200], dtype=np.int16), VAD_CHUNK_SAMPLES // 2)
        events = detector._process_vad_chunk(chunk)

        self.assertIsInstance(events, list)
        self.assertIsInstance(detector.is_vad_active, bool)

        detector._vad_active = True
        detector._vad_silence_frames = 3
        detector._vad_buffer = chunk.copy()
        detector.reset()

        self.assertFalse(detector.is_vad_active)
        self.assertEqual(detector._vad_silence_frames, 0)
        self.assertEqual(detector._vad_buffer.size, 0)


if __name__ == "__main__":
    unittest.main()
