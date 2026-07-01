---
name: checkpoint
description: Save a cognitive snapshot — what you're doing, why, decisions made, and what's next. Use before ending a session, before /compact, when context is getting long, or anytime you want to preserve reasoning for a future session.
argument-hint: [feature name]
---

# Checkpoint

Save a cognitive snapshot of current work for future sessions.

## Step 1: Identify feature

Find active progress file in `.lifecycle/plans/` (look for files with incomplete `[ ]` or `[~]` tasks). If no active progress file, ask: "No active plan found. What are you working on?" Use the answer as the feature name.

## Step 2: Write checkpoint

Write `.lifecycle/checkpoints/[feature-slug]-checkpoint.md`:

```markdown
# Checkpoint: [feature]
**Saved:** [ISO timestamp]
**Task:** [current task from progress file]
**Progress:** [N/M tasks complete]

## Context
[What I'm doing and why — 2-3 sentences max]

## Decisions Made
- [Decision]: [reasoning] — one line each

## What's Next
1. [Concrete next step]
2. [Step after that]

## Gotchas
- [Things the next session should watch for]
```

Slugify the feature name (lowercase, spaces to hyphens) for the filename. Overwrite previous checkpoint for the same feature — only the latest matters.

## Step 3: Confirm

```
Checkpoint saved for [feature]. Resume with /resume or recover with /recover.
```

Rules:
- Lightweight — should take <5 seconds and <200 tokens to invoke
- No git commit (it's a working state, not a milestone)
- Focus on reasoning and decisions, not file lists

$ARGUMENTS
