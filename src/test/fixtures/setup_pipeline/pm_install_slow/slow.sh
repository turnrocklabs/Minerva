#!/usr/bin/env bash
# Slow-but-successful build step (~2s) — wide enough window for the
# remove-while-S_BUILDING guard test to act mid-build, short enough to keep
# the suite fast. Exits 0 so the pipeline terminates in "registered".
sleep 2
exit 0
