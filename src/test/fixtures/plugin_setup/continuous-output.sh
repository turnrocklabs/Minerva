#!/bin/sh
set -eu
while :; do
  printf 'continuous-stdout-abcdefghijklmnopqrstuvwxyz-0123456789\n'
  printf 'continuous-stderr-abcdefghijklmnopqrstuvwxyz-0123456789\n' >&2
done
