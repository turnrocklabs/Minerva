#!/usr/bin/env bash
# Fixture F9: sleeps far longer than any timeout_s a test declares, to
# exercise the executor's hard-kill-on-deadline path.
sleep 30
