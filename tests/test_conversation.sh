#!/bin/bash
set -eu
exec python3 -B "$(dirname "${BASH_SOURCE[0]}")/test_conversation.py"
