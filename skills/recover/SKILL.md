---
name: recover
description: Recover work from a crashed or interrupted session. Use when Claude crashed mid-task, after an unexpected exit, when you see 'stale sessions detected', or when you lost context and need to figure out what was happening.
argument-hint: [feature name]
---

# Recover Session

Recover work from a session that ended unexpectedly.

**NOTE:** For resuming planned features (with progress files), use `/resume` instead.

## Phase 0: Check checkpoints

1. Look for checkpoint files in `.lifecycle/checkpoints/`
2. If found, present cognitive state alongside recovery data — not just "these files changed" but "you were doing X because Y"

## Phase 0.5: Check WIP branches

3. Check for `wip/` branches: `git branch --list 'wip/*'`
4. If found, present:
   ```
   WIP safety branches found:
     wip/project-20260331-1445 (2h ago) — 3 files saved
     wip/project-20260331-1200 (5h ago) — 1 file saved
   ```
5. Offer: "Restore latest WIP branch? (merges saved files into current branch)"
6. If user accepts: `git merge --no-commit wip/[branch]` then delete the wip branch
7. If user declines: continue to Phase 1

## Phase 1: Check crash logs (active-changes.log)

8. Check `~/.claude/sessions/active-changes.log` and `~/.claude/sessions/active-changes-*.log`
9. If no logs found, note: "No session hooks detected. Crash log recovery requires hooks that write to ~/.claude/sessions/active-changes.log. See continuum README for setup." Then skip to Phase 2.
10. Parse `# SESSION` headers for `cwd`, `sid`, `started`
11. Extract unique EDIT/WRITE file paths and COMMIT history
12. Extract last `STATE:` line
13. Determine each file's state via git:
   - `git status --porcelain -- <file>` → `~` still modified
   - `git log --oneline --since="<started>" -- <file>` → `+` committed
   - Neither → `x` lost

14. Present:
   ```
   Crashed session recovered:
   Feature: [name] | Task: [from checkpoint or STATE]

   Checkpoint (if available):
   Context: [what was happening]
   Next: [what was planned next]

   Files ([N] edits across [M] files):
     ~ src/api/routes.ts — still modified
     + src/middleware/auth.ts — committed (abc1234)
     x tests/auth.test.ts — lost

   Resume from here, start fresh with this context, or discard?
   ```

15. **Resume** → continue working, delete logs. **Fresh** → present as context. **Discard** → delete logs.

## Phase 2: Legacy session JSON files

16. Scan `~/.claude/sessions/session-*.json` for `"status": "active"`
17. Same recovery flow as Phase 1

## Edge Cases

- No checkpoints, no logs, no JSONs: "No crashed sessions. Did you mean /resume?"
- Sessions older than 7 days: flag as "likely stale" but allow recovery
- Log with no EDIT/WRITE entries: show task only, note "no file changes tracked"
- Not a git repo: skip file status analysis

$ARGUMENTS
