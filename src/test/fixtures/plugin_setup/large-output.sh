#!/bin/sh
set -eu
i=0
while [ "$i" -lt 6000 ]; do
  printf 'stdout-%06d-abcdefghijklmnopqrstuvwxyz-0123456789\n' "$i"
  printf 'stderr-%06d-abcdefghijklmnopqrstuvwxyz-0123456789\n' "$i" >&2
  i=$((i + 1))
done
printf 'FINAL-STDERR-MARKER\n' >&2
exit 7
