"""Real pipe child: READY synchronizes tests before stdin EOF is delivered."""
import os
import signal
import sys
import time

mode = sys.argv[1]
if mode == 'ignore':
    # Default termination behavior proves escalation, rather than self-exit.
    print('READY', flush=True)
    sys.stdin.buffer.read()
    time.sleep(60)
else:
    # On Unix a signal is distinguishable from clean EOF exit in the oracle.
    if hasattr(signal, 'SIGTERM'):
        signal.signal(signal.SIGTERM, lambda *_: os._exit(73))
    print('READY', flush=True)
    sys.stdin.buffer.read()
    if mode == 'flood':
        # More than pipe capacity and the native line cap, including stderr.
        for _ in range(4096):
            os.write(1, b'x' * 1024 + b'\n')
            os.write(2, b'diagnostic\n')
    time.sleep(1)
    os.write(2, b'EOF shutdown completed\n')
    sys.exit(0)
