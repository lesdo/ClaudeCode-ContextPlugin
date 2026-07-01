---
name: align
description: Audit project structure, docs health, and lifecycle compliance. Use when a project feels disorganized, after major refactors, before onboarding a contributor, or periodically as a health check.
argument-hint: [project path]
---

# Align Project

Audit this project's structure and lifecycle compliance. Report a health score, then fix issues on approval.

## Step 1: Scan (no changes)

Check each dimension and score 0-10:

| Dimension | Check |
|-----------|-------|
| Lifecycle directory | `.lifecycle/` exists with subdirs: plans/, checkpoints/, lessons/, archive/ |
| CLAUDE.md | Exists and under 200 lines |
| CLAUDE.md quality | Doesn't contain things Claude can infer from code |
| Rules frontmatter | `.claude/rules/` files have `paths:` (plural). Flag `path:` (singular) as misconfiguration |
| Rules freshness | No stale rules referencing paths that don't exist |
| Plan hygiene | No completed plans (all `[x]`) still in .lifecycle/plans/ — should be archived |
| Lessons freshness | Any `.lifecycle/lessons/` files updated in last 30 days? |
| Test structure | Test directories mirror source directories |

**Health score:** average across dimensions, rounded to nearest integer.

Also check v1.x locations as fallback:
- `docs/05-Plans/` for stale plans
- `docs/06-Development/lessons.md` for unmigrated lessons

## Step 2: Present and approve

Show health score with breakdown table. List proposed fixes. Wait for approval.

## Step 3: Execute fixes

- Use `git mv` for moves (preserve history)
- Create missing directories
- Fix `.claude/rules/` frontmatter issues
- Archive completed plans to `.lifecycle/archive/`
- Migrate v1.x lessons to `.lifecycle/lessons/` topic files if found
- Commit: `refactor(align): fix [N] issues, health score [before] → [after]`

## Step 4: Verify

Show final health score and tree (2 levels deep).

Rules: Never delete — archive to `.lifecycle/archive/`. Ask before making structural changes to close-enough setups.

$ARGUMENTS
