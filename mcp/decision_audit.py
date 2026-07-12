#!/usr/bin/env python3
"""ax5: Decision audit and outcome review — the feedback loop that makes the plugin smarter."""

import json
import os
from typing import Optional
from datetime import datetime, timezone, timedelta

from db_core import get_db, new_id, now_iso


def decision_log(project_dir: Optional[str] = None,
                 decision_type: str = "",
                 input_conditions: Optional[dict] = None,
                 decision_output: Optional[dict] = None,
                 expected_outcome: Optional[str] = None,
                 session_id: Optional[str] = None) -> dict:
    """Record an automatic decision for later outcome review.

    Called by decay_run, crash_diagnose, dedup_run, analysis_scheduler
    to log decisions that should be reviewed for accuracy over time.
    """
    dec_id = new_id()
    with get_db(project_dir) as conn:
        conn.execute("""
            INSERT INTO decision_audit (id, decision_type, input_conditions,
                decision_output, expected_outcome, session_id)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (
            dec_id,
            decision_type,
            json.dumps(input_conditions or {}, ensure_ascii=False),
            json.dumps(decision_output or {}, ensure_ascii=False),
            expected_outcome,
            session_id,
        ))
    return {"id": dec_id, "type": decision_type, "status": "logged"}


def outcome_review(project_dir: Optional[str] = None,
                   decision_type: Optional[str] = None,
                   min_age_days: Optional[int] = None) -> dict:
    """Review past decisions and verify their outcomes.

    Queries decision_audit for unverified decisions older than min_age_days,
    checks the actual outcome against what was expected, and scores accuracy.

    For decay decisions: checks if archived memories were ever accessed again.
    For crash_diagnose: compares diagnosis with the session's final status.
    For dedup decisions: checks if the superseded memory was missed (re-created).
    """
    if min_age_days is None:
        min_age_days = int(os.environ.get('CP_REVIEW_MIN_AGE', '7'))

    cutoff = (datetime.now(timezone.utc) - timedelta(days=min_age_days)).isoformat()
    results = {'reviewed': 0, 'verified': 0, 'needs_review': 0, 'accuracy_avg': 0.0, 'findings': []}

    with get_db(project_dir) as conn:
        # Get unverified decisions older than cutoff
        query = """
            SELECT * FROM decision_audit
            WHERE outcome_verified = 0 AND created_at < ?
        """
        params = [cutoff]
        if decision_type:
            query += " AND decision_type = ?"
            params.append(decision_type)
        query += " ORDER BY created_at ASC LIMIT 100"

        decisions = conn.execute(query, params).fetchall()
        scores = []

        for d in decisions:
            decision = dict(d)
            review = _review_decision(conn, decision)
            scores.append(review['accuracy'])
            results['findings'].append(review)
            results['reviewed'] += 1

            if review['accuracy'] >= 0.7:
                results['verified'] += 1
                conn.execute("""
                    UPDATE decision_audit
                    SET outcome_verified=1, accuracy_score=?, actual_outcome=?,
                        reviewed_at=?
                    WHERE id=?
                """, (review['accuracy'], json.dumps(review.get('actual', {}), ensure_ascii=False),
                      now_iso(), decision['id']))
            else:
                results['needs_review'] += 1
                conn.execute("""
                    UPDATE decision_audit
                    SET outcome_verified=2, accuracy_score=?, actual_outcome=?,
                        reviewed_at=?
                    WHERE id=?
                """, (review['accuracy'], json.dumps(review.get('actual', {}), ensure_ascii=False),
                      now_iso(), decision['id']))

        if scores:
            results['accuracy_avg'] = round(sum(scores) / len(scores), 3)

        # Log the review
        conn.execute("""
            INSERT INTO maintenance_log (operation, items_affected, details)
            VALUES ('outcome_review', ?, ?)
        """, (results['reviewed'], json.dumps({
            'verified': results['verified'],
            'needs_review': results['needs_review'],
            'accuracy_avg': results['accuracy_avg'],
        })))

    return results


def _review_decision(conn, decision: dict) -> dict:
    """Review a single decision's outcome. Returns accuracy 0-1 and details."""
    dtype = decision['decision_type']
    dec_id = decision['id']

    try:
        inputs = json.loads(decision['input_conditions'] or '{}')
        outputs = json.loads(decision['decision_output'] or '{}')
    except json.JSONDecodeError:
        return {'id': dec_id, 'type': dtype, 'accuracy': 0.5, 'note': 'unparseable', 'actual': {}}

    if dtype == 'decay':
        return _review_decay(conn, inputs, outputs)
    elif dtype == 'crash_diagnose':
        return _review_crash(conn, inputs, outputs)
    elif dtype == 'dedup':
        return _review_dedup(conn, inputs, outputs)
    else:
        # Generic review: mark as unverifiable for now
        return {'id': dec_id, 'type': dtype, 'accuracy': 0.5,
                'note': 'no review logic for this type yet', 'actual': {}}


def _review_decay(conn, inputs: dict, outputs: dict) -> dict:
    """Review a decay decision: check if archived memories were accessed.
    Accuracy = 1.0 if archived memories were never accessed again (correct decay).
    Accuracy = 0.3 if archived memory was accessed (should not have been archived).
    """
    mem_type = inputs.get('type', '')
    archived_count = outputs.get('archived', 0)
    extended_count = outputs.get('extended', 0)

    # Check if any memories of this type that were archived still get accessed
    # (simplified: check for recent access patterns)
    recent = conn.execute("""
        SELECT COUNT(*) as cnt FROM memories
        WHERE type=? AND expires_at IS NOT NULL AND access_count > 0
        AND updated_at > expires_at
    """, (mem_type,)).fetchone()

    if archived_count == 0:
        return {'id': '', 'type': 'decay', 'accuracy': 1.0,
                'note': 'nothing to archive — correct', 'actual': {'archived': 0}}

    # Higher accuracy if we extended some (indicating weighted decay worked)
    accuracy = 0.8
    if extended_count > 0:
        accuracy = 0.9  # Weighted decay prevented premature archiving
    if recent and recent['cnt'] > 0:
        accuracy = 0.4  # Some archived memories were still in use

    return {'id': '', 'type': 'decay', 'accuracy': accuracy,
            'note': f'archived={archived_count}, extended={extended_count}',
            'actual': {'archived': archived_count, 'extended': extended_count,
                       'post_archive_access': recent['cnt'] if recent else 0}}


def _review_crash(conn, inputs: dict, outputs: dict) -> dict:
    """Review a crash diagnosis: compare with actual session outcome."""
    slug = inputs.get('slug', '')
    diag_severity = outputs.get('severity', 'L3')

    # Check actual session status
    session = conn.execute(
        "SELECT status, abandoned FROM sessions WHERE slug=? ORDER BY created_at DESC LIMIT 1",
        (slug,)
    ).fetchone()

    if not session:
        return {'id': '', 'type': 'crash_diagnose', 'accuracy': 0.5,
                'note': 'session not found', 'actual': {}}

    actual_status = session['status']
    is_abandoned = session['abandoned']

    # Score based on diagnosis accuracy
    if actual_status == 'completed' and diag_severity == 'L0':
        accuracy = 1.0  # Correct: diagnosed as normal, was normal
    elif actual_status in ('skeleton', 'active') and diag_severity in ('L1', 'L2', 'L3'):
        accuracy = 0.9  # Correctly identified as abnormal
    elif actual_status == 'completed' and diag_severity != 'L0':
        accuracy = 0.2  # False positive: diagnosed as crash but was normal
    elif actual_status != 'completed' and diag_severity == 'L0':
        accuracy = 0.2  # False negative: diagnosed as normal but was crash
    else:
        accuracy = 0.6  # Partial match

    return {'id': '', 'type': 'crash_diagnose', 'accuracy': accuracy,
            'note': f'diag={diag_severity} vs actual={actual_status}',
            'actual': {'status': actual_status, 'abandoned': bool(is_abandoned)}}


def _review_dedup(conn, inputs: dict, outputs: dict) -> dict:
    """Review a dedup decision: check if the superseded memory was re-created."""
    similar_to = outputs.get('similar_to', '')
    mem_id = outputs.get('mem_id', '')

    # Check if a memory very similar to the superseded one was created later
    if not similar_to:
        return {'id': '', 'type': 'dedup', 'accuracy': 1.0,
                'note': 'no superseding — skip', 'actual': {}}

    # Simplification: check if the superseded ID is referenced by newer memories
    newer = conn.execute("""
        SELECT COUNT(*) as cnt FROM memories
        WHERE supersedes=? AND created_at > (
            SELECT created_at FROM memories WHERE id=?
        )
    """, (similar_to, similar_to)).fetchone()

    accuracy = 0.85  # Default: dedup is usually safe
    if newer and newer['cnt'] > 0:
        accuracy = 0.5  # Some memories still point to superseded — dedup may be wrong

    return {'id': '', 'type': 'dedup', 'accuracy': accuracy,
            'note': f'superseded={similar_to}, newer_refs={newer["cnt"] if newer else 0}',
            'actual': {'newer_refs_to_superseded': newer['cnt'] if newer else 0}}
