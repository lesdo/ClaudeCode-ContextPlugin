#!/usr/bin/env bash
# PostToolUse hook: auto-save uncommitted work every 10 edits.
# Creates wip/ branches as safety net against crashes and data loss.
# Token cost: 0 (command hook, no LLM)
set -euo pipefail

INPUT="$(cat)"
CWD="$(echo "$INPUT" | sed -n 's/.*"cwd" *: *"\([^"]*\)".*/\1/p')"
CWD="${CWD//\\//}"

if [[ -z "$CWD" ]]; then
  exit 0
fi

LIFECYCLE_DIR="$CWD/.lifecycle"

# Only run if this project uses .lifecycle/
[[ -d "$LIFECYCLE_DIR" ]] || exit 0

# Must be a git repo
git -C "$CWD" rev-parse --git-dir &>/dev/null || exit 0

COUNTER_FILE="$LIFECYCLE_DIR/.wip-counter"

COUNT=0
if [[ -f "$COUNTER_FILE" ]]; then
  COUNT="$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)"
fi
COUNT=$(( COUNT + 1 ))
echo "$COUNT" > "$COUNTER_FILE"

# Only trigger every 10 edits
if (( COUNT % 10 != 0 )); then
  exit 0
fi

cd "$CWD"
DIRTY="$(git status --porcelain 2>/dev/null)"
if [[ -z "$DIRTY" ]]; then
  echo "0" > "$COUNTER_FILE"
  exit 0
fi

# Skip if committed recently (within 5 minutes)
LAST_COMMIT_AGE="$(git log -1 --format=%cr 2>/dev/null || echo "unknown")"
if echo "$LAST_COMMIT_AGE" | grep -qE '^[0-4] minutes? ago$'; then
  exit 0
fi

TIMESTAMP="$(date +%Y%m%d-%H%M)"
PROJECT_NAME="$(basename "$CWD")"
WIP_BRANCH="wip/${PROJECT_NAME}-${TIMESTAMP}"
ORIGINAL_BRANCH="$(git branch --show-current 2>/dev/null || echo "HEAD")"

# Stash dirty work, create wip branch from it, restore working state
git stash push -m "wip-auto-save $TIMESTAMP" --quiet 2>/dev/null || exit 0
git stash branch "$WIP_BRANCH" &>/dev/null || {
  git stash pop --quiet 2>/dev/null
  exit 0
}
git checkout "$ORIGINAL_BRANCH" --quiet 2>/dev/null
git stash pop --quiet 2>/dev/null || true

echo "0" > "$COUNTER_FILE"
exit 0
