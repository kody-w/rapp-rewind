#!/bin/bash
# Deterministic, local-only regression checks. Never captures the user's screen.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$HERE/dryrun.py" "$@"
