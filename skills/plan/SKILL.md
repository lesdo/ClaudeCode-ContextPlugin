---
name: plan
description: Create a structured implementation plan with sized tasks and acceptance criteria. Use when starting any non-trivial feature (3+ steps), when a task feels ambiguous, or when you need to break down a large request before coding.
argument-hint: <feature or request>
---

# Create Plan

Analyze this request and create a structured implementation plan.

## Before planning

Check `.lifecycle/lessons/` for lessons on relevant topics. Also check `docs/06-Development/lessons.md` as v1.x fallback. Skip if neither exists.

## Create plan file

Write `.lifecycle/plans/[name]-plan.md`:

```markdown
# [Feature Name] Plan

## Summary
[2-3 sentences. What and why.]

## Tasks
1. [S] Task — acceptance criteria in one line
2. [M] Task — criteria
3. [L] Task — criteria

## Dependencies
[Only if tasks depend on each other. Skip if none.]

## Open Questions
[Anything ambiguous. Skip if clear.]
```

Rules:
- One line per task. No paragraphs, no prose.
- Complexity: S = <30min, M = 1-3hrs, L = 3hrs+
- Reference external docs instead of inlining
- Write detailed specs upfront to reduce ambiguity during execution

## Present and wait

Show summary and any open questions. Do NOT start coding until approved.

## On approval

1. Create `.lifecycle/plans/[name]-progress.md`:
   ```markdown
   # [Feature Name] Progress

   [ ] Task 1
   [ ] Task 2
   [ ] Task 3
   ```
2. Begin executing the first task immediately (same session)
3. Update progress as tasks complete: `[ ]` → `[x]`
4. Do NOT ask between tasks — execute to completion
5. If context limit approaching: run `/checkpoint`, commit, `/compact`, resume with `/resume`
6. If something goes sideways mid-execution: STOP and re-plan

Request: $ARGUMENTS
