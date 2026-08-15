#!/bin/bash
# Run every test suite. Exit non-zero on any failure.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$HERE"/test_*.sh; do echo "== $(basename "$t")"; "$t" || rc=1; done
exit "$rc"
