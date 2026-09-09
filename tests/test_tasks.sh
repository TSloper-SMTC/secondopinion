#!/bin/bash
# Task mailbox lifecycle and CLI integration; all stores are isolated.
set -eu
exec python3 -B "$(dirname "${BASH_SOURCE[0]}")/test_task_mailbox.py"
