#!/usr/bin/env bash
# Exercises the executor's 2KB stderr_tail cap: prints well over 2KB to
# stderr with a distinctive marker at the very start and the very end, then
# fails, so a test can assert the captured tail keeps END-MARKER and drops
# START-MARKER.
printf 'START-MARKER\n' 1>&2
for i in $(seq 1 200); do
	printf 'padding-line-%03d-------------------------------\n' "$i" 1>&2
done
printf 'END-MARKER\n' 1>&2
exit 1
