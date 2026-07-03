---
name: recover
description: Recover work from a crashed or interrupted session. Use when Claude crashed mid-task, after an unexpected exit, when you see 'stale sessions detected', or when you lost context and need to figure out what was happening.
argument-hint: [feature name]
---

# Recover Session

Recover work from a session that ended unexpectedly.

**NOTE:** For resuming planned features (with progress files), use `/resume` instead.

**Infrastructure:** This skill works with the `.log` forensic log + `.session-index` system. No git or external tools required.

## Phase 0: Check session index for skeletons

1. Look at `.claude/context/sessions/.session-index` — find entries with `"status":"skeleton"`
2. Cross-reference with `.log` files: skeleton + CRASH line = crashed session
3. If SessionStart hook already ran crash auto-fill, the skeleton's `## 自动信息` section will contain the auto-filled data — read it first

## Phase 1: Examine crashed session files

4. Read the crashed session's `.md` file — check if `## 自动信息` was auto-filled (by P0 crash auto-fill)
5. Read the crashed session's `.log` file — contains the full tool call history
6. Look for `CRASH:` line in `.log` — gives exit_code, label, time
7. `CRASH_SEVERITY` from SessionStart output tells you the impact level:
   - **L1** — short session, minimal loss, auto-filled
   - **L2** — meaningful work, forensic data available, auto-filled
   - **L3** — data missing, needs manual investigation

## Phase 2: Present recovery summary

8. Based on what you found, present:

```
Crashed session: [session-name]
Severity: [L1/L2/L3] | Exit: [exit_code] ([label])

What happened (from .log):
  - HH:MM:SS ToolName summary
  - HH:MM:SS ToolName summary
  ...

Auto-fill status: [已自动填充 / 无数据可填充]

Resume from here, start fresh with this context, or discard?
```

9. **Resume** → continue working with the recovered context. **Fresh** → present findings as context only. **Discard** → acknowledge and move on.

## Phase 3: Manual recovery (L3 / no auto-fill)

10. If auto-fill didn't run or data is incomplete:
    - Read `.log` to see what tools were called
    - Check project directory for modified files (compare file timestamps with session start time in session `.md`)
    - Fill the session `.md` `## 上下文` section manually with what you can reconstruct
    - Update `.session-index` entry from `skeleton` to `complete`

## Edge Cases

- No skeletons in index: "No crashed sessions detected. Did you mean /resume?"
- L1 severity: Note that loss was minimal, no action needed
- Sessions older than 7 days: flag as "likely stale" but allow recovery
- `.log` exists but no CRASH line: session ended without crash detection — check exit code in `.md`
- `.log` missing entirely: L3, cannot recover from forensic data

$ARGUMENTS
