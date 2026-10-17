#!/bin/bash
# Build verified optional data; never execute Wine or edit a bottle.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -B scripts/build-compatibility-pack.py "$@"
