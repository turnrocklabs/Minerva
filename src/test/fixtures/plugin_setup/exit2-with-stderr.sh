#!/usr/bin/env bash
# Fixture F7: a step that fails with a non-zero exit and stderr output, to
# exercise the setup_step_failed envelope's exit_code + stderr_tail fields.
echo "boom: something went wrong" 1>&2
exit 2
