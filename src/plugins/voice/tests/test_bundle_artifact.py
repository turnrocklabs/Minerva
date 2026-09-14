"""Validate a built sidecar without using system Python or network access."""

from __future__ import annotations

import hashlib
from importlib import metadata
import os
from pathlib import Path
import platform
import socket
import unittest


class BundleArtifactTest(unittest.TestCase):
    def test_manifest_runtime_models_and_offline_detector(self) -> None:
        root = Path(os.environ["MINERVA_VOICE_BUNDLE_ROOT"]).resolve()
        expected_target = os.environ["MINERVA_VOICE_TARGET"]
        self.assertEqual((root / "target-triple.txt").read_text(encoding="utf-8").strip(), expected_target)
        manifest = root / "manifest.sha256"
        self.assertTrue(manifest.is_file())
        for line in manifest.read_text(encoding="utf-8").splitlines():
            expected, relative = line.split("  ", 1)
            payload = root / relative
            self.assertTrue(payload.is_file(), relative)
            self.assertEqual(hashlib.sha256(payload.read_bytes()).hexdigest(), expected, relative)

        from minerva_voice_worker.detector import VoiceDetector
        from openwakeword.model import Model as OWWModel
        from openwakeword.utils import AudioFeatures
        import numpy as np

        model = Path(__import__("minerva_voice_worker").__file__).with_name("models") / "minerva_wakeword.onnx"
        real_connect = socket.socket.connect

        def reject_non_loopback(sock, address):
            host = address[0] if isinstance(address, tuple) else ""
            if host not in ("127.0.0.1", "::1", "localhost"):
                raise AssertionError(f"detector attempted network access: {host}")
            return real_connect(sock, address)

        socket.socket.connect = reject_non_loopback
        try:
            detector = VoiceDetector(model)
            initial_features = detector._features.feature_buffer.copy()
            nonzero = np.tile(np.array([1200, -1200], dtype=np.int16), 640)
            vad_events = detector.process_audio(nonzero.tobytes())
            self.assertIsInstance(vad_events, list)
            self.assertIsInstance(detector.is_vad_active, bool)
            self.assertFalse(np.array_equal(detector._features.feature_buffer, initial_features))
            detector.reset()
            self.assertEqual(detector._vad_buffer.size, 0)
            self.assertEqual(detector._oww_buffer.size, 0)
            np.testing.assert_array_equal(detector._features.feature_buffer, initial_features)

            # The worker bypasses only openWakeWord's unused classifiers. Its
            # direct feature path must stay numerically equivalent to the
            # established Model preprocessor for identical streaming input.
            pcm = np.tile(np.array([1200, -1200], dtype=np.int16), 640)
            # Exercise Model.predict's historical preprocessing call without
            # running a classifier whose native input rank differs from the
            # separate flat Minerva classifier.
            established = OWWModel.__new__(OWWModel)
            established.preprocessor = AudioFeatures(ncpu=1)
            established.speex_ns = None
            established.models = {}
            established.vad_threshold = 0
            direct = AudioFeatures(ncpu=1)
            established.predict(pcm)
            direct(pcm)
            np.testing.assert_allclose(
                established.preprocessor.feature_buffer,
                direct.feature_buffer,
                rtol=0,
                atol=1e-6,
            )
        finally:
            socket.socket.connect = real_connect

        machine = platform.machine().lower()
        expected_arches = {
            "linux-x86_64": {"x86_64", "amd64"},
            "linux-arm64": {"aarch64", "arm64"},
            "macos-amd64": {"x86_64", "amd64"},
            "macos-arm64": {"aarch64", "arm64"},
            "windows-x86_64": {"x86_64", "amd64"},
        }
        self.assertIn(machine, expected_arches[expected_target])

    def test_installed_distribution_dependencies_are_closed(self) -> None:
        from packaging.requirements import Requirement

        for distribution in metadata.distributions():
            for raw_requirement in distribution.requires or []:
                requirement = Requirement(raw_requirement)
                if requirement.marker is not None and not requirement.marker.evaluate({"extra": ""}):
                    continue
                installed = metadata.version(requirement.name)
                self.assertIn(installed, requirement.specifier, raw_requirement)


if __name__ == "__main__":
    unittest.main()
