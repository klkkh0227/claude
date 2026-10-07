#!/bin/bash
# Install the Python packages the geo-* skills' scripts need, in cloud sessions only.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

pip install -q -r "$CLAUDE_PROJECT_DIR/.claude/hooks/requirements.txt"
