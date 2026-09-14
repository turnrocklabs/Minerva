# Minerva voice runtime third-party inventory

The runtime build records exact input files and SHA-256 values in
`input-artifacts.sha256`. Python wheel metadata and license files remain in
each installed `.dist-info` directory.

| Component | Pinned version | Source | License |
| --- | --- | --- | --- |
| CPython / python-build-standalone | 3.12.13 / 20260510 | https://github.com/astral-sh/python-build-standalone | PSF-2.0 / MPL-2.0 |
| openWakeWord and packaged feature models | 0.4.0 | https://github.com/dscripka/openWakeWord | Apache-2.0 |
| Silero VAD model distributed by openWakeWord | openWakeWord 0.4.0 asset | https://github.com/snakers4/silero-vad | MIT |
| ONNX Runtime | 1.22.1 | https://github.com/microsoft/onnxruntime | MIT |
| NumPy | 2.2.6 | https://github.com/numpy/numpy | BSD-3-Clause |
| SciPy | 1.15.3 | https://github.com/scipy/scipy | BSD-3-Clause |
| scikit-learn | 1.7.0 | https://github.com/scikit-learn/scikit-learn | BSD-3-Clause |
| websockets | 15.0.1 | https://github.com/python-websockets/websockets | BSD-3-Clause |
| tqdm | 4.67.1 | https://github.com/tqdm/tqdm | MPL-2.0 AND MIT |

The Minerva classifier (`minerva_wakeword.onnx` and its external data file)
is a project asset. Its hashes are pinned in `scripts/runtime-bundle.lock`.
The smaller support packages pinned in `scripts/requirements-runtime.lock`
retain their wheel metadata and license files in the bundle.
