#!/usr/bin/env bash
set -euo pipefail

ERRORS=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check 1: SKILL.md frontmatter
echo "=== Check 1: SKILL.md frontmatter ==="
VALIDATED=0
for skill_dir in "$ROOT_DIR"/skills/*/; do
  [ -d "$skill_dir" ] || continue
  skill_name="$(basename "$skill_dir")"
  skill_file="$skill_dir/SKILL.md"

  if [[ ! -f "$skill_file" ]]; then
    echo "FAIL: $skill_name/ missing SKILL.md"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Extract name from frontmatter
  name=$(sed -n '/^---$/,/^---$/{ /^name:/{ s/^name: *//; p; } }' "$skill_file" | head -1)
  if [[ -z "$name" ]]; then
    echo "FAIL: $skill_name/SKILL.md missing 'name' in frontmatter"
    ERRORS=$((ERRORS + 1))
  elif [[ "$name" != "$skill_name" ]]; then
    echo "FAIL: $skill_name/SKILL.md name '$name' doesn't match directory"
    ERRORS=$((ERRORS + 1))
  fi

  # Extract description from frontmatter
  desc=$(sed -n '/^---$/,/^---$/{ /^description:/p; }' "$skill_file" | head -1)
  if [[ -z "$desc" ]]; then
    echo "FAIL: $skill_name/SKILL.md missing 'description' in frontmatter"
    ERRORS=$((ERRORS + 1))
  fi

  VALIDATED=$((VALIDATED + 1))
done
if [[ "$VALIDATED" -gt 0 ]] && [[ "$ERRORS" -eq 0 ]]; then
  echo "OK: $VALIDATED skills validated"
fi
echo ""

# Check 2: Skill count matches plugin.json
echo "=== Check 2: Skill count ==="
SKILL_COUNT=0
for f in "$ROOT_DIR"/skills/*/SKILL.md; do
  [[ -f "$f" ]] && SKILL_COUNT=$((SKILL_COUNT + 1))
done
PLUGIN_COUNT=$(grep -oE '[0-9]+ Claude Code skills' "$ROOT_DIR/.claude-plugin/plugin.json" | grep -oE '[0-9]+' | head -1)
if [[ -z "${PLUGIN_COUNT:-}" ]]; then
  echo "FAIL: Could not parse skill count from plugin.json description"
  ERRORS=$((ERRORS + 1))
elif [[ "$SKILL_COUNT" -ne "$PLUGIN_COUNT" ]]; then
  echo "FAIL: Found $SKILL_COUNT skills but plugin.json says $PLUGIN_COUNT"
  ERRORS=$((ERRORS + 1))
else
  echo "OK: $SKILL_COUNT skills match plugin.json"
fi
echo ""

# Check 3: Version format (semver)
echo "=== Check 3: Version format ==="
VERSION=$(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' "$ROOT_DIR/.claude-plugin/plugin.json" | head -1)
if [[ -z "$VERSION" ]]; then
  echo "FAIL: Could not parse version from plugin.json"
  ERRORS=$((ERRORS + 1))
elif [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
  echo "FAIL: Version '$VERSION' is not valid semver"
  ERRORS=$((ERRORS + 1))
else
  echo "OK: Version $VERSION"
fi
echo ""

# Check 4: No stale references
echo "=== Check 4: No stale references ==="
STALE_TERMS=("whateverai" "dev-skills" "workflow-skills" "plan-linear" "18 commands" "17 commands")
FOUND_STALE=0
for term in "${STALE_TERMS[@]}"; do
  # Search shipped markdown only (README, skills/), exclude CHANGELOG
  matches=""
  if [[ -f "$ROOT_DIR/README.md" ]]; then
    matches=$(grep -il "$term" "$ROOT_DIR/README.md" 2>/dev/null || true)
  fi
  skill_matches=$(grep -rl "$term" "$ROOT_DIR/skills/" 2>/dev/null || true)
  if [[ -n "$skill_matches" ]]; then
    matches="$matches $skill_matches"
  fi
  matches=$(echo "$matches" | xargs)
  if [[ -n "$matches" ]]; then
    echo "FAIL: Found '$term' in: $matches"
    ERRORS=$((ERRORS + 1))
    FOUND_STALE=1
  fi
done
if [[ "$FOUND_STALE" -eq 0 ]]; then
  echo "OK: No stale references"
fi
echo ""

# Summary
echo "=== Summary ==="
if [[ "$ERRORS" -gt 0 ]]; then
  echo "FAILED: $ERRORS check(s) failed"
  exit 1
else
  echo "PASSED: All checks passed"
  exit 0
fi
