#!/bin/bash
# Build and launch ClaudeNotch.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

# Kill any previous instance so we always run the fresh build.
pkill -x ClaudeNotch 2>/dev/null || true

open ClaudeNotch.app
echo "▸ ClaudeNotch launched."
