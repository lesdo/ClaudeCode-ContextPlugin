---
name: resume
description: Resume in-progress work from where you left off. Use when returning to a feature after a break, starting a new session on ongoing work, or after /compact. Shows progress and picks up the next task.
argument-hint: [feature name]
---

# Resume Feature

Resume in-progress work. If $ARGUMENTS given, match that feature. Otherwise find the most recent active progress file.

## Step 1: Find progress

1. Search `.lifecycle/plans/` for progress files with incomplete tasks (`[ ]` or `[~]`)
2. Also check `docs/05-Plans/` as v1.x fallback
3. If multiple found: list with last-modified timestamps, ask user to select
4. If none found: "No in-progress plans found. Try `/recover` for crashed sessions or `/plan` for new work."

## Step 2: Show status

```
Feature: [name] | Progress: [N]/[M] tasks
Done: Task 1, Task 2, Task 3
Next: Task 4 — [description]
```

## Step 3: Check checkpoints

Look for `.lifecycle/checkpoints/[feature]-checkpoint.md`. If found, show cognitive state:

```
Last checkpoint ([time ago]):
Context: [what was happening]
Next steps: [planned next actions]
Gotcha: [warnings for this session]
```

## Step 4: Check activity log

Read `.lifecycle/activity.md` if it exists. Show the last 3 sessions:

```
Recent sessions:
  [2026-03-31T14:30:00Z] auth-system — 4/8 tasks, branch: feat/auth, files: 12
  [2026-03-30T10:15:00Z] auth-system — 2/8 tasks, branch: feat/auth, files: 8
  [2026-03-29T16:00:00Z] auth-system — 0/8 tasks, branch: feat/auth, files: 3
```

Skip if file doesn't exist or has no entries.

## Step 5: Check lessons

Read `.lifecycle/lessons/[relevant topics].md` for applicable lessons. Also check `docs/06-Development/lessons.md` as v1.x fallback. Skip if neither exists.

## Step 6: Continue

1. Read plan file ONLY for the next incomplete task's details
2. Continue from next `[ ]` or `[~]` task
3. Update progress as tasks complete — one line per task, no prose
4. Do NOT ask between tasks — execute to completion
5. If context limit approaching: run `/checkpoint`, commit, `/compact`, resume
6. If something goes sideways: STOP and re-plan

$ARGUMENTS
