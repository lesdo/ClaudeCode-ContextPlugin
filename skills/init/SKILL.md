---
name: init
description: Bootstrap a project with structured docs, CLAUDE.md, and lifecycle directory. Use when starting a new project, onboarding to an existing repo, or when a project has no CLAUDE.md or organized structure.
argument-hint: [project path]
---

# Initialize Project

Bootstrap this project with a CLAUDE.md and `.lifecycle/` directory for the context plugin workflow.

## Step 1: Scan (no changes yet)

Detect from config files:
1. **Stack**: package.json, pyproject.toml, Cargo.toml, go.mod, etc.
2. **Commands**: dev server, build, test, lint from scripts/Makefile/docker-compose
3. **Database**: ORM configs, .env, docker-compose services
4. **Test framework**: Jest, Vitest, Playwright, pytest, etc. and where tests live
5. **Existing structure**: current folder layout, any existing CLAUDE.md or .lifecycle/
6. **Project size**: count source files (<20 = small, 20-100 = medium, 100+ = large)

Present:
```
Project: [name] | Stack: [detected] | Size: [small/medium/large]
Dev: [cmd] | Test: [cmd] | DB: [type or "none"]
```

## Step 2: Confirm

Show analysis. Ask two questions:
1. "Is this accurate?"
2. "Should .lifecycle/ be git-tracked or gitignored?"

Wait for answers before proceeding.

## Step 3: Create .lifecycle/

```
.lifecycle/
├── plans/
├── checkpoints/
├── lessons/
└── archive/
```

If user chose gitignored: add `.lifecycle/` to `.gitignore`.

## Step 4: Generate CLAUDE.md

Follow Anthropic best practices. Under 200 lines. Only things Claude can't infer from code.

```markdown
# Project

[One sentence — only if README.md doesn't exist or is unclear]

# Commands

- Dev: `[detected]`
- Build: `[detected]`
- Test: `[detected]`
- Lint: `[detected]`
- Single test: `[detected]`

# Code style

<!-- Only rules that DIFFER from language defaults. Delete this comment and add rules, or delete the section. -->

# Architecture decisions

<!-- Only non-obvious choices Claude would get wrong. Delete this comment and add decisions, or delete the section. -->

# Gotchas

<!-- Things that will break Claude if not warned. Delete this comment and add gotchas, or delete the section. -->

# References

See @.lifecycle/lessons/ for patterns learned from past work
```

Preserve any existing project-specific rules from a pre-existing CLAUDE.md.

## Step 5: Rules files (medium/large projects only)

- **Small** (<20 source files): everything in CLAUDE.md, skip rules files
- **Medium** (20-100 files): suggest 1-2 `.claude/rules/` files based on detected domains
- **Large** (100+ files): scaffold `.claude/rules/` with path-scoped files

Rules file format:
```markdown
---
paths:
  - src/api/**
  - src/routes/**
---
- Rule in one line
- Another rule
```

## Step 6: Commit and verify

Commit: `docs(setup): initialize project structure and CLAUDE.md`

```
✅ Project initialized
   CLAUDE.md: created/updated ([N] lines)
   .lifecycle/: created ([tracked/gitignored])
   Rules: [N] files (or "none — small project")
   Ready: /plan, /resume, /checkpoint, /align
```

Rules: Never delete existing files (archive instead). Never guess stack — ask if unclear. Keep CLAUDE.md focused on what Claude can't infer from code.

$ARGUMENTS
