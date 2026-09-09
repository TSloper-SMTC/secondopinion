#!/bin/bash
set -eu
python3 -B "$(dirname "${BASH_SOURCE[0]}")/test_wakeup.py"
python3 -B "$(dirname "${BASH_SOURCE[0]}")/test_wake_service.py"
exec python3 -B "$(dirname "${BASH_SOURCE[0]}")/test_worker_directory.py"
