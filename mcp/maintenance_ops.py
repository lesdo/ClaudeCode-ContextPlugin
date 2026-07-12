#!/usr/bin/env python3
"""
Maintenance operations: decay, dedup, health.
Extracted from session_ops.py v3.1 — ax7: file complexity limit.
"""

import json
import math
import os
from typing import Optional
from datetime import datetime, timezone, timedelta

from db_core import get_db, jaccard_similarity, now_iso


# ── Decay TTL Configuration (ax4: env-var overridable) ──

def _get_decay_config() -> dict:
    """Get decay TTL config from env vars with defaults."""
    return {
        'pattern': None,
        'decision': None,
        'preference': None,
        'semantic': int(os.environ.get('CP_TTL_SEMANTIC', '30')),
        'procedural': int(os.environ.get('CP_TTL_PROCEDURAL', '60')),
        'episodic': int(os.environ.get('CP_TTL_EPISODIC', '7')),
    }

DECAY_CONFIG = _get_decay_config()  # kept for backward compat in tests


def _effective_ttl(base_ttl_days: int, access_count: int = 0, confidence: float = 1.0) -> float:
    """ax3: weighted TTL — type x access_count factor x confidence.
    Formula: base_ttl x (1 + ln(access_count + 1) / 10) x confidence
    """
    access_factor = 1.0 + math.log(access_count + 1) / 10.0
    return base_ttl_days * access_factor * confidence


def decay_run(project_dir: Optional[str] = None) -> dict:
    """Run type-aware, access-weighted decay on memories. ax3 + ax4."""
    now = datetime.now(timezone.utc)
    config = _get_decay_config()
    deep_mult = float(os.environ.get('CP_DECAY_DEEP_MULT', '3.0'))
    results = {'archived': 0, 'deleted': 0, 'examined': 0, 'extended': 0}

    with get_db(project_dir) as conn:
        for mem_type, base_ttl in config.items():
            if base_ttl is None:
                continue

            candidates = conn.execute("""
                SELECT id, access_count, confidence, updated_at, expires_at
                FROM memories
                WHERE type=? AND expires_at IS NULL
            """, (mem_type,)).fetchall()

            results['examined'] += len(candidates)

            for row in candidates:
                eff_ttl = _effective_ttl(base_ttl, row['access_count'], row['confidence'])
                cutoff = now - timedelta(days=eff_ttl)

                updated_str = row['updated_at']
                if updated_str:
                    try:
                        updated_dt = datetime.fromisoformat(updated_str)
                        if updated_dt.tzinfo is None:
                            updated_dt = updated_dt.replace(tzinfo=timezone.utc)
                    except ValueError:
                        continue
                else:
                    continue

                if updated_dt < cutoff:
                    conn.execute(
                        "UPDATE memories SET expires_at=? WHERE id=?",
                        (now.isoformat(), row['id'])
                    )
                    results['archived'] += 1
                    if eff_ttl > base_ttl * 1.05:
                        results['extended'] += 1

            # Phase 2: delete expired beyond deep cutoff (per-memory weighted)
            expired = conn.execute("""
                SELECT id, access_count, confidence, expires_at
                FROM memories
                WHERE type=? AND expires_at IS NOT NULL
            """, (mem_type,)).fetchall()

            for row in expired:
                eff_ttl = _effective_ttl(base_ttl, row['access_count'], row['confidence'])
                deep_cutoff = now - timedelta(days=eff_ttl * deep_mult)

                expires_str = row['expires_at']
                if expires_str:
                    try:
                        expires_dt = datetime.fromisoformat(expires_str)
                        if expires_dt.tzinfo is None:
                            expires_dt = expires_dt.replace(tzinfo=timezone.utc)
                    except ValueError:
                        continue
                else:
                    continue

                if expires_dt < deep_cutoff:
                    conn.execute("DELETE FROM memories WHERE id=?", (row['id'],))
                    results['deleted'] += 1

        conn.execute("""
            INSERT INTO maintenance_log (operation, items_affected, details)
            VALUES ('decay_run', ?, ?)
        """, (results['archived'] + results['deleted'], json.dumps(results)))

        # ax5: decision audit for feedback loop
        try:
            from decision_audit import decision_log
            decision_log(project_dir=project_dir,
                         decision_type='decay',
                         input_conditions={'config': {k: v for k, v in config.items() if v},
                                          'deep_mult': deep_mult},
                         decision_output=results,
                         expected_outcome='memories past effective TTL archived; low-access ones deleted')
        except Exception:
            pass  # ax6 note: decision logging is best-effort, not critical path
    return results


def dedup_run(project_dir: Optional[str] = None, dry_run: bool = False) -> list:
    """Run batch dedup on memories."""
    near_dup = float(os.environ.get('CP_JACCARD_NEAR_DUP', '0.85'))
    supersede = float(os.environ.get('CP_JACCARD_SUPERSEDE', '0.95'))
    findings = []
    with get_db(project_dir) as conn:
        groups = conn.execute("""
            SELECT type, count(*) as cnt FROM memories
            WHERE type IN ('semantic', 'episodic', 'procedural')
            GROUP BY type HAVING cnt > 1
        """).fetchall()
        for g in groups:
            rows = conn.execute(
                "SELECT id, content FROM memories WHERE type=? ORDER BY created_at",
                (g['type'],)
            ).fetchall()
            for i in range(len(rows)):
                for j in range(i + 1, len(rows)):
                    sim = jaccard_similarity(rows[i]['content'], rows[j]['content'])
                    if sim > near_dup:
                        findings.append({
                            'type': g['type'],
                            'id_a': rows[i]['id'],
                            'id_b': rows[j]['id'],
                            'similarity': round(sim, 3),
                        })
                        if not dry_run and sim > supersede:
                            conn.execute(
                                "UPDATE memories SET supersedes=?, updated_at=? WHERE id=?",
                                (rows[i]['id'], now_iso(), rows[j]['id'])
                            )
        if not dry_run:
            conn.execute("""
                INSERT INTO maintenance_log (operation, items_affected, details)
                VALUES ('dedup_run', ?, ?)
            """, (len(findings), json.dumps(findings)))
            # ax5: decision audit
            try:
                from decision_audit import decision_log
                decision_log(project_dir=project_dir,
                             decision_type='dedup',
                             input_conditions={'near_dup': near_dup, 'supersede': supersede},
                             decision_output={'findings': len(findings), 'superseded': sum(1 for f in findings if f.get('similarity', 0) > supersede)},
                             expected_outcome='near-duplicates flagged; high-similarity ones auto-superseded')
            except Exception:
                pass
    return findings
