#!/usr/bin/env bash
# SessionStart hook: detect in-progress .lifecycle/ plans and prompt user
# Token cost: 0 (command hook, no LLM)
set -euo pipefail

# Read CWD from stdin JSON
INPUT="$(cat)"
CWD="$(echo "$INPUT" | sed -n 's/.*"cwd" *: *"\([^"]*\)".*/\1/p')"
CWD="${CWD//\\//}"

if [[ -z "$CWD" ]]; then
  CWD="$(pwd)"
  CWD="${CWD//\\//}"
fi

LIFECYCLE_DIR="$CWD/.lifecycle"
PLANS_DIR="$LIFECYCLE_DIR/plans"
CHECKPOINT_DIR="$LIFECYCLE_DIR/checkpoints"

# Only run if this project uses .lifecycle/
[[ -d "$PLANS_DIR" ]] || exit 0

# Find active progress files
ACTIVE_FEATURES=()
for f in "$PLANS_DIR"/*-progress.md; do
  [[ -f "$f" ]] || continue
  if grep -qE '^\[[ ~]\]' "$f" 2>/dev/null; then
    FEATURE="$(basename "$f" | sed 's/-progress\.md$//')"
    TOTAL=$(grep -cE '^\[.\]' "$f" 2>/dev/null) || TOTAL=0
    DONE=$(grep -cE '^\[x\]' "$f" 2>/dev/null) || DONE=0
    NEXT="$(grep -m1 -E '^\[[ ~]\]' "$f" | sed 's/^\[.\] //' || echo "unknown")"
    ACTIVE_FEATURES+=("$FEATURE|$DONE|$TOTAL|$NEXT")
  fi
done

[[ ${#ACTIVE_FEATURES[@]} -gt 0 ]] || exit 0

# Check for checkpoint
echo "Active work detected:"
for entry in "${ACTIVE_FEATURES[@]}"; do
  IFS='|' read -r FEATURE DONE TOTAL NEXT <<< "$entry"
  echo "  $FEATURE — $DONE/$TOTAL tasks done, next: $NEXT"

  # Show checkpoint age if exists
  CKPT="$CHECKPOINT_DIR/${FEATURE}-checkpoint.md"
  if [[ -f "$CKPT" ]]; then
    CKPT_DATE="$(grep '^\*\*Saved:\*\*' "$CKPT" | sed 's/\*\*Saved:\*\* //' | sed 's/ .*//')"
    if [[ -n "$CKPT_DATE" ]]; then
      echo "  Last checkpoint: $CKPT_DATE"
    fi
  fi
done
echo "Run /resume to continue or /plan for new work."

exit 0
