#!/usr/bin/env bash
# Fixture F8: exits cleanly (0) but deliberately writes nothing, to exercise
# the post-step artifact check failing after a successful exit code
# (setup_step_failed with exit_code 0 + artifact_expected set).
exit 0
