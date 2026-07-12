#!/usr/bin/env python3
"""Opus adversarial review pipeline — v1.0.0
ax10 two-phase: Red(find) -> Blue(refute) -> Auditor(judge)
ax5 feedback: all findings logged to decision_audit for outcome_review
Trigger: analysis-scheduler.sh (deterministic, every N sessions)

TODO(ax5): accumulate N opus_review outcome_review records
→ evaluate CP_OPUS_INTERVAL / _MAX_REVIEW_FILES adaptive tuning
(ax4: thresholds need >=3 battle-tested rounds before hardcoding)

Pipeline split:
  Phase A (scheduler): opus_review_prep() — compute diff, prepare context
  Phase B (agent):     opus_review_submit() — store review findings

The scheduler calls prep() deterministically. The agent reads the briefing,
performs the actual code review using its Opus capability, and submits findings.
"""

import os as _os
import json
import sys
import subprocess
from typing import Optional
from datetime import datetime, timezone

from db_core import get_db, new_id, now_iso


# ax4: thresholds env-configurable with rationale. Not yet battle-tested (need 3+ rounds).
# Per-file Opus review costs ~3-5K tokens. 10 files = ~40K budget per session.
_MAX_REVIEW_FILES = int(_os.environ.get('CP_OPUS_MAX_FILES', '10'))
# 1-2 file changes are usually typo fixes — not worth adversarial triage overhead.
_MIN_CHANGED_FILES = int(_os.environ.get('CP_OPUS_MIN_FILES', '3'))
# Context listing is cheap (filenames only); 15 gives agent overview without token bloat.
_MAX_CONTEXT_FILES = int(_os.environ.get('CP_OPUS_CONTEXT_FILES', '15'))


def opus_review_prep(project_dir: Optional[str] = None,
                      base_ref: str = 'HEAD~1') -> dict:
    """Phase A: prepare review context from git diff since last review.
    Called deterministically by analysis-scheduler.sh.

    Returns {ready: bool, files: [...], review_prompt: str, session_id: str}
    ready=false means not enough changed files to warrant review.
    """
    project_dir = project_dir or _os.getcwd()

    # Get changed files since last review (or since base_ref)
    changed = _get_changed_files(project_dir, base_ref)
    if not changed:
        return {"ready": False, "reason": "no changed files found", "files": []}

    # Filter to reviewable files (skip generated, data, binary)
    reviewable = _filter_reviewable(changed, project_dir)
    if len(reviewable) < _MIN_CHANGED_FILES:
        return {
            "ready": False,
            "reason": f"only {len(reviewable)} reviewable files (min {_MIN_CHANGED_FILES})",
            "files": reviewable[:10],
        }

    # Build review prompt with structured context
    files_for_review = reviewable[:_MAX_REVIEW_FILES]
    diffs = _get_file_diffs(project_dir, files_for_review, base_ref)

    review_prompt = _build_review_prompt(files_for_review, diffs)

    # Store prep state in DB for the agent to pick up
    prep_id = new_id()
    with get_db(project_dir) as conn:
        conn.execute("""
            INSERT OR REPLACE INTO review_pipeline_state
            (id, session_signals, updated_at)
            VALUES (1, ?, ?)
        """, (json.dumps({
            "prep_id": prep_id,
            "files": files_for_review,
            "base_ref": base_ref,
            "prepared_at": now_iso(),
            "status": "prepared",
            "total_changed": len(reviewable),
        }, ensure_ascii=False), now_iso()))

    return {
        "ready": True,
        "prep_id": prep_id,
        "files": files_for_review[:_MAX_CONTEXT_FILES],
        "total_changed": len(reviewable),
        "review_prompt": review_prompt,
    }


def opus_review_submit(project_dir: Optional[str] = None,
                        findings: Optional[list] = None,
                        session_id: Optional[str] = None) -> dict:
    """Phase B: agent submits review findings. Stores to decision_audit (ax5).

    Each finding: {phase, severity, category, file, line, title, description,
                    red_flag, blue_challenge, auditor_verdict, fix_suggestion}
    phase = 'confirmed' | 'refuted'
    """
    project_dir = project_dir or _os.getcwd()
    findings = findings or []
    if not findings:
        return {"status": "skipped", "submitted": 0, "reason": "no findings"}

    submitted = 0
    confirmed = 0
    refuted = 0

    with get_db(project_dir) as conn:
        for f in findings:
            fid = new_id()
            phase = f.get('phase', 'suspect')
            severity = f.get('severity', 'medium')
            category = f.get('category', 'architecture')

            # Store to decision_audit for outcome_review feedback loop (ax5)
            decision_input = {
                "file": f.get('file', ''),
                "line": f.get('line', 0),
                "title": f.get('title', ''),
                "category": category,
            }
            decision_output = {
                "phase": phase,
                "severity": severity,
                "description": f.get('description', ''),
                "red_flag": f.get('red_flag', ''),
                "blue_challenge": f.get('blue_challenge', ''),
                "auditor_verdict": f.get('auditor_verdict', ''),
                "fix_suggestion": f.get('fix_suggestion', ''),
            }

            conn.execute("""
                INSERT INTO decision_audit
                (id, decision_type, input_conditions, decision_output,
                 expected_outcome, session_id)
                VALUES (?, 'opus_review', ?, ?, ?, ?)
            """, (
                fid,
                json.dumps(decision_input, ensure_ascii=False),
                json.dumps(decision_output, ensure_ascii=False),
                f.get('fix_suggestion', ''),
                session_id,
            ))

            submitted += 1
            if phase == 'confirmed':
                confirmed += 1
            elif phase == 'refuted':
                refuted += 1

        # Update pipeline state
        conn.execute("""
            UPDATE review_pipeline_state
            SET session_signals = json_set(
                COALESCE(session_signals, '{}'),
                '$.last_review_at', ?,
                '$.last_review_findings', ?,
                '$.status', 'reviewed'
            ),
            total_opus_reviews = COALESCE(total_opus_reviews, 0) + 1,
            updated_at = ?
            WHERE id = 1
        """, (now_iso(), submitted, now_iso()))

    return {
        "status": "completed",
        "submitted": submitted,
        "confirmed": confirmed,
        "refuted": refuted,
    }


def opus_review_state(project_dir: Optional[str] = None) -> dict:
    """Get current review pipeline state (read-only)."""
    project_dir = project_dir or _os.getcwd()
    with get_db(project_dir) as conn:
        row = conn.execute(
            "SELECT * FROM review_pipeline_state WHERE id = 1"
        ).fetchone()
        if not row:
            return {"status": "no_state", "total_reviews": 0}
        return {
            "status": "active",
            "total_reviews": row['total_opus_reviews'] or 0,
            "last_review_at": row['last_opus_review_at'],
            "signals": json.loads(row['session_signals'] or '{}'),
        }


# ═══════════════════════════════════════════════════════════════
# Internal helpers
# ═══════════════════════════════════════════════════════════════

_REVIEWABLE_EXTS = {'.py', '.sh', '.bash', '.js', '.ts', '.jsx', '.tsx',
                     '.json', '.yaml', '.yml', '.toml', '.md', '.txt'}

_SKIP_PATTERNS = ['generated', 'auto-generated', '.min.', 'package-lock',
                   'yarn.lock', 'pnpm-lock', '.svg', '.png', '.jpg']


def _get_changed_files(project_dir: str, base_ref: str) -> list:
    """Get list of files changed since base_ref."""
    try:
        result = subprocess.run(
            ['git', 'diff', '--name-only', base_ref, 'HEAD'],
            capture_output=True, text=True, cwd=project_dir,
            timeout=10,
        )
        if result.returncode != 0:
            # Try diff against HEAD~1 if base_ref fails
            result = subprocess.run(
                ['git', 'diff', '--name-only', 'HEAD~1', 'HEAD'],
                capture_output=True, text=True, cwd=project_dir,
                timeout=10,
            )
        files = [f.strip() for f in result.stdout.split('\n') if f.strip()]
        return files
    except Exception as e:
        print(f"[adversarial] git diff 失败: {e}", file=sys.stderr)
        return []


def _filter_reviewable(files: list, project_dir: str) -> list:
    """Filter to files worth reviewing (skip generated, binary, minified)."""
    reviewable = []
    for f in files:
        # Skip deleted files
        fpath = _os.path.join(project_dir, f)
        if not _os.path.exists(fpath):
            continue
        # Skip non-reviewable extensions
        _, ext = _os.path.splitext(f)
        if ext.lower() not in _REVIEWABLE_EXTS:
            continue
        # Skip generated patterns
        if any(p in f.lower() for p in _SKIP_PATTERNS):
            continue
        reviewable.append(f)
    return reviewable


def _get_file_diffs(project_dir: str, files: list, base_ref: str) -> dict:
    """Get diff for specific files. Returns {filename: diff_text}."""
    diffs = {}
    for f in files:
        try:
            result = subprocess.run(
                ['git', 'diff', base_ref, 'HEAD', '--', f],
                capture_output=True, text=True, cwd=project_dir,
                timeout=5,
            )
            if result.stdout:
                # Truncate very long diffs (token budget)
                diff_text = result.stdout
                if len(diff_text) > 8000:
                    diff_text = diff_text[:8000] + '\n... (truncated)'
                diffs[f] = diff_text
        except Exception as e:
            print(f"[adversarial] diff 失败 {f}: {e}", file=sys.stderr)
    return diffs


def _build_review_prompt(files: list, diffs: dict) -> str:
    """Build structured review prompt for the agent.

    The prompt follows the Red/Blue/Auditor triage structure:
    - Red: find potential issues (security, architecture, correctness)
    - Blue: challenge each finding (could this be intentional?)
    - Auditor: final judgment with fix suggestion
    """
    file_list = '\n'.join(f'  - {f}' for f in files)
    diff_summary = '\n'.join(
        f'### {f}\n```diff\n{diffs.get(f, "(no diff available)")}\n```'
        for f in files[:5]  # Only include first 5 diffs inline
    )

    prompt = f"""## Opus Adversarial Review Request

**Files changed:** {len(files)} files since last review
{file_list}

**Review protocol — Red/Blue/Auditor triage (ax10):**

### Red Team (Find issues):
For each file, identify potential problems:
- Security: command injection, path traversal, secret leaks, unsafe permissions
- Architecture: KDNA axiom violations, file complexity drift, missing extension points
- Correctness: logic errors, race conditions, missing error handling
- Style: silent error suppression (ax6), hardcoded thresholds (ax4), single-dimension judgments (ax3)

### Blue Team (Challenge):
For each Red finding, argue why it might be intentional or acceptable:
- Is this a deliberate design decision documented somewhere?
- Is there a legitimate reason for this pattern in context?
- Is the finding based on incomplete understanding?

### Auditor (Judge):
For each Red finding + Blue challenge pair, produce a final verdict:
- **confirmed**: the finding is real and should be addressed
- **refuted**: the Blue challenge is convincing, the finding is not actionable

### Output format:
Submit findings using the opus_review_submit tool with this JSON structure:
```json
{{
  "findings": [
    {{
      "phase": "confirmed",
      "severity": "critical|high|medium|low",
      "category": "security|architecture|correctness|style",
      "file": "path/to/file",
      "line": 123,
      "title": "Brief issue title",
      "description": "What's wrong and why it matters",
      "red_flag": "Original Red team observation",
      "blue_challenge": "Blue team counter-argument",
      "auditor_verdict": "Why confirmed/refuted",
      "fix_suggestion": "Specific, actionable fix"
    }}
  ]
}}
```

**Diff context (first 5 files):**
{diff_summary}

---
*Triggered by analysis-scheduler (deterministic, every N sessions).
Use opus_review_submit to record findings. All findings are stored in
decision_audit for outcome_review feedback loop (ax5).*
"""
    return prompt
