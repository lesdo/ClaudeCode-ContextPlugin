---
name: reflect
description: Extract lessons from completed work and archive the plan. Use after finishing a feature, when all tasks are done, or when you want to capture what you learned before moving on.
argument-hint: [feature name]
---

# Reflect

Extract lessons learned from completed work, then archive the plan.

## Step 0: Check for v1.x migration

If `.lifecycle/lessons/` is empty and `docs/06-Development/lessons.md` exists, offer to migrate existing lessons into topic files before proceeding.

## Step 1: Find completed plan

1. Search `.lifecycle/plans/` for progress files with all tasks `[x]`. Also check `docs/05-Plans/` as v1.x fallback.
2. If $ARGUMENTS given, match that feature name.
3. If no completed plans: "No completed plans found. Finish your tasks first, or specify the feature name."

## Step 2: Analyze

Read the plan, progress, and checkpoint files. Analyze git history for the feature's commits.

Identify patterns:
- **Corrections** — tasks re-planned or re-done (evidence: `[!]` blocked states, re-planning commits, tasks marked done then reopened)
- **Surprises** — S tasks that took M/L effort, or vice versa
- **Discoveries** — new tools, patterns, or gotchas encountered
- **What worked** — approaches worth repeating

## Step 3: Present and approve

Show findings and proposed lessons. Wait for approval before writing.

## Step 4: Write lessons

Append approved lessons to `.lifecycle/lessons/[topic].md`:

```markdown
- [YYYY-MM-DD] Lesson in one line
```

Topic detection:
- Infer from plan content, file paths touched, and git diff domains
- Common topics: testing, architecture, performance, tooling, database, api, frontend, deployment
- If unsure, use `general.md`
- Don't duplicate existing lessons. Create new topic files as needed.

## Step 5: Archive

Move plan + progress + checkpoint to `.lifecycle/archive/`.

Commit: `docs(reflect): archive [feature] with [N] new lessons`

## Step 6: Summary

```
Reflected on: [feature]
Lessons added: [N] ([topic]: [count], [topic]: [count])
Archived: plan + progress + checkpoint
```

$ARGUMENTS
