#!/bin/bash
# 共享断言 — 所有测试脚本 source 此文件
# 用法: source "$(dirname "$0")/assert.sh"

PASS=0; FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label: $actual"
  else
    fail "$label: got=[$actual] expected=[$expected]"
  fi
}

assert_ge() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" -ge "$expected" ] 2>/dev/null; then
    pass "$label: $actual >= $expected"
  else
    fail "$label: got=$actual expected>=$expected"
  fi
}

assert_file() {
  local label="$1" file="$2"
  if [ -f "$file" ]; then
    pass "$label: $file"
  else
    fail "$label: file missing ($file)"
  fi
}

assert_contains() {
  local label="$1" file="$2" pattern="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label: pattern '$pattern' not found in $file"
  fi
}

finish() {
  echo ""
  echo "  $PASS PASS / $FAIL FAIL / $((PASS+FAIL)) TOTAL"
  [ $FAIL -eq 0 ]
}
