#!/usr/bin/env python3
"""Orphan session recovery — 3D weighted scoring (ax9 + ax10).
v5.0: time-based liveness (ax9), two-phase abandon via suspect_at (ax10),
      decision_audit integration (ax5), all thresholds env-configurable (ax4).
"""

import os as _os
from datetime import datetime, timezone, timedelta
from typing import Optional

from db_core import get_db

# ═══════════════════════════════════════════════════════════════
# Thresholds — all env-configurable (ax4)
# Rationale: orphan detection is new, no battle-tested defaults yet;
# every threshold must be tunable without code changes.
# TODO(ax5): accumulate N outcome_review records → evaluate adaptive tuning
# ═══════════════════════════════════════════════════════════════

_EVENT_NONE = int(_os.environ.get('CP_ORPHAN_TIME_NONE', '40'))
_EVENT_OLD_H = int(_os.environ.get('CP_ORPHAN_TIME_OLD_H', '2'))
_EVENT_OLD_SCORE = int(_os.environ.get('CP_ORPHAN_TIME_OLD_SCORE', '30'))
_EVENT_RECENT_H = int(_os.environ.get('CP_ORPHAN_TIME_RECENT_H', '1'))
_EVENT_RECENT_SCORE = int(_os.environ.get('CP_ORPHAN_TIME_RECENT_SCORE', '15'))
_EVENT_FEW = int(_os.environ.get('CP_ORPHAN_EVENT_FEW', '3'))
_EVENT_FEW_PENALTY = int(_os.environ.get('CP_ORPHAN_EVENT_FEW_PENALTY', '10'))

_PID_DEAD = int(_os.environ.get('CP_ORPHAN_PID_DEAD', '35'))
_PID_NONE = int(_os.environ.get('CP_ORPHAN_PID_NONE', '20'))
_PID_UNKNOWN = int(_os.environ.get('CP_ORPHAN_PID_UNKNOWN', '15'))

_CHK_NONE = int(_os.environ.get('CP_ORPHAN_CHK_NONE', '25'))
_CHK_WINDOW_H = int(_os.environ.get('CP_ORPHAN_CHK_WINDOW_H', '2'))

_ABANDON = int(_os.environ.get('CP_ORPHAN_ABANDON_SCORE', '60'))
_REVIEW = int(_os.environ.get('CP_ORPHAN_REVIEW_SCORE', '30'))
_COOLDOWN = int(_os.environ.get('CP_ORPHAN_COOLDOWN_MIN', '30'))


def _check_checkpoint_reference(checkpoint_dir, slug, session_id, start_dt, errors):
    """Scan .lifecycle/checkpoints/*.md for evidence this session was checkpointed.
    Returns (score, reason_string). Errors appended to errors[] list (ax6: fail-safe)."""
    if not _os.path.isdir(checkpoint_dir):
        return _CHK_NONE, "no_checkpoint_dir"

    window_h = _CHK_WINDOW_H
    window_start = start_dt - timedelta(hours=window_h)
    window_end = start_dt + timedelta(hours=window_h)
    found_nearby = False

    try:
        entries = _os.listdir(checkpoint_dir)
    except OSError as e:
        errors.append(f"checkpoint_list_error:{e}")
        return _CHK_NONE, "checkpoint_list_error"

    for fname in entries:
        if not fname.endswith('.md'):
            continue
        fpath = _os.path.join(checkpoint_dir, fname)

        # Check mtime window
        try:
            mtime = datetime.fromtimestamp(_os.path.getmtime(fpath), tz=timezone.utc)
        except OSError as e:
            errors.append(f"checkpoint_mtime_error:{fname}:{e}")
            continue

        if window_start <= mtime <= window_end:
            found_nearby = True

        # Best-effort: check file content for slug/session_id reference
        try:
            with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read(4096)
            if slug in content or session_id[:8] in content:
                return 0, "checkpoint_references"
        except (IOError, OSError) as e:
            errors.append(f"checkpoint_read_error:{fname}:{e}")
            continue

    if found_nearby:
        return 0, "checkpoint_nearby"
    return _CHK_NONE, "no_checkpoint"


def session_orphan_scan(project_dir: Optional[str] = None,
                        auto_abandon: bool = False) -> dict:
    """Scan active sessions for orphans using 3D weighted scoring.

    Dimensions (ax9: signal priority — time > count):
      1. last_event (0-40): time since last event
      2. pid (0-35): process liveness via os.kill(pid, 0)
      3. checkpoint (0-25): recoverability evidence

    ax10 two-phase abandon (when auto_abandon=True):
      - score >= ABANDON, no suspect_at → set suspect_at=NOW(), log decision
      - score >= ABANDON, suspect_at exists + past cooldown → mark abandoned
      - score >= REVIEW → flag for user attention
      - score < REVIEW → keep (likely legitimate)

    Returns dict with scanned count, per-session scores, recommendations, errors.
    """
    project_dir = project_dir or _os.getcwd()
    errors = []

    try:
        with get_db(project_dir) as conn:
            # Exclude newest active (current session)
            cur = conn.execute(
                "SELECT id, slug FROM sessions WHERE status='active' "
                "ORDER BY created_at DESC LIMIT 1"
            ).fetchone()

            if not cur:
                return {
                    "scanned": 0, "sessions": [],
                    "recommendations": {"abandon": 0, "review": 0, "keep": 0, "suspect": 0},
                    "current_session": None, "errors": errors
                }
            current_dict = {"id": cur["id"], "slug": cur["slug"]}

            rows = conn.execute(
                "SELECT id, slug, pid, start_time, suspect_at FROM sessions "
                "WHERE status='active' AND id != ? "
                "ORDER BY created_at DESC",
                (cur["id"],)
            ).fetchall()
    except Exception as e:
        return {"error": str(e), "scanned": 0, "sessions": [],
                "recommendations": {}, "current_session": None, "errors": [str(e)]}

    results = []
    rec_counts = {"abandon": 0, "review": 0, "keep": 0, "suspect": 0}
    checkpoint_dir = _os.path.join(project_dir, '.lifecycle', 'checkpoints')
    now_utc = datetime.now(timezone.utc)

    for row in rows:
        reasons = []
        total = 0

        # ── Dimension 1: last_event (ax9: time interval, not count) ──
        try:
            with get_db(project_dir) as conn2:
                ev = conn2.execute(
                    "SELECT COUNT(*) AS cnt, MAX(created_at) AS last_ctime "
                    "FROM events WHERE session_id=?",
                    (row["id"],)
                ).fetchone()
        except Exception:
            ev = None
            errors.append(f"event_query_error:{row['slug']}")

        event_count = ev["cnt"] if ev else 0
        last_ctime = ev["last_ctime"] if ev else None

        if event_count == 0:
            total += _EVENT_NONE
            reasons.append(f"no_events:{_EVENT_NONE}")
        elif last_ctime:
            try:
                last_dt = datetime.fromisoformat(last_ctime)
                if last_dt.tzinfo is None:
                    last_dt = last_dt.replace(tzinfo=timezone.utc)
                age_h = (now_utc - last_dt).total_seconds() / 3600.0

                if age_h > _EVENT_OLD_H:
                    total += _EVENT_OLD_SCORE
                    reasons.append(f"event_stale:{age_h:.1f}h:{_EVENT_OLD_SCORE}")
                elif age_h > _EVENT_RECENT_H:
                    total += _EVENT_RECENT_SCORE
                    reasons.append(f"event_old:{age_h:.1f}h:{_EVENT_RECENT_SCORE}")
                else:
                    reasons.append(f"event_recent:{age_h:.1f}h:0")

                # ax9: event count as auxiliary penalty only
                if event_count < _EVENT_FEW and age_h > _EVENT_OLD_H:
                    total += _EVENT_FEW_PENALTY
                    reasons.append(f"few_events_penalty:{event_count}:{_EVENT_FEW_PENALTY}")
            except (ValueError, TypeError):
                total += _EVENT_NONE
                reasons.append(f"event_parse_error:{_EVENT_NONE}")
        else:
            total += _EVENT_NONE
            reasons.append(f"no_event_timestamp:{_EVENT_NONE}")

        # ── Dimension 2: pid ──
        pid = row["pid"]
        if pid is None:
            total += _PID_NONE
            reasons.append(f"no_pid:{_PID_NONE}")
        else:
            try:
                _os.kill(pid, 0)
                reasons.append(f"pid_alive:{pid}:0")
            except ProcessLookupError:
                total += _PID_DEAD
                reasons.append(f"pid_dead:{pid}:{_PID_DEAD}")
            except OSError:
                total += _PID_UNKNOWN
                reasons.append(f"pid_unknown:{pid}:{_PID_UNKNOWN}")

        # ── Dimension 3: checkpoint ──
        if row["start_time"]:
            try:
                start_dt = datetime.fromisoformat(row["start_time"])
                if start_dt.tzinfo is None:
                    start_dt = start_dt.replace(tzinfo=timezone.utc)
                cp_score, cp_reason = _check_checkpoint_reference(
                    checkpoint_dir, row["slug"], row["id"], start_dt, errors
                )
            except (ValueError, TypeError):
                cp_score, cp_reason = _CHK_NONE, "start_time_parse_error"
                errors.append(f"start_time_parse:{row['slug']}")
        else:
            cp_score, cp_reason = _CHK_NONE, "no_start_time"
        total += cp_score
        reasons.append(cp_reason)

        # ── Recommendation (ax10: two-phase) ──
        suspect_at = row["suspect_at"]
        if total >= _ABANDON:
            if suspect_at:
                # Phase 2: previously suspected, check cooldown
                try:
                    suspect_dt = datetime.fromisoformat(suspect_at)
                    if suspect_dt.tzinfo is None:
                        suspect_dt = suspect_dt.replace(tzinfo=timezone.utc)
                    cooldown_passed = (now_utc - suspect_dt).total_seconds() / 60.0 >= _COOLDOWN
                except (ValueError, TypeError):
                    cooldown_passed = True  # can't parse timestamp, err on safe side

                if cooldown_passed:
                    rec = "abandon"
                else:
                    rec = "suspect"  # still in cooldown, keep as suspect
            else:
                rec = "suspect"  # Phase 1: first detection
        elif total >= _REVIEW:
            rec = "review"
        else:
            rec = "keep"
        rec_counts[rec] = rec_counts.get(rec, 0) + 1

        results.append({
            "session_id": row["id"],
            "slug": row["slug"],
            "pid": pid,
            "event_count": event_count,
            "last_event": last_ctime,
            "orphan_score": total,
            "reasons": reasons,
            "recommendation": rec,
            "start_time": row["start_time"],
            "suspect_at": suspect_at,
        })

    # ── Auto-abandon (ax10: Phase 2 only; Phase 1 just sets suspect) ──
    if auto_abandon:
        from session_ops import session_mark_abandoned
        try:
            from decision_audit import decision_log
        except ImportError:
            decision_log = None

        for s in results:
            if s["recommendation"] == "abandon":
                try:
                    session_mark_abandoned(project_dir, session_id=s["session_id"])
                    if decision_log:
                        try:
                            decision_log(project_dir,
                                decision_type="orphan_abandon",
                                input_conditions={
                                    "slug": s["slug"], "score": s["orphan_score"],
                                    "reasons": s["reasons"]
                                },
                                decision_output={"action": "mark_abandoned", "phase": 2},
                                expected_outcome="Session correctly identified as orphan"
                            )
                        except Exception as e:
                            errors.append(f"decision_log_error:{s['slug']}:{e}")
                    s["abandoned"] = True
                except Exception as e:
                    errors.append(f"abandon_error:{s['slug']}:{e}")
                    s["abandoned"] = False

            elif s["recommendation"] == "suspect" and not s.get("suspect_at"):
                # Phase 1: set suspect marker
                try:
                    with get_db(project_dir) as conn:
                        conn.execute(
                            "UPDATE sessions SET suspect_at=? WHERE id=?",
                            (now_utc.isoformat(), s["session_id"])
                        )
                    if decision_log:
                        try:
                            decision_log(project_dir,
                                decision_type="orphan_suspect",
                                input_conditions={
                                    "slug": s["slug"], "score": s["orphan_score"],
                                    "reasons": s["reasons"]
                                },
                                decision_output={"action": "mark_suspect", "phase": 1},
                                expected_outcome="Session confirmed or cleared on next scan"
                            )
                        except Exception as e:
                            errors.append(f"decision_log_error:{s['slug']}:{e}")
                    s["suspect_set"] = True
                except Exception as e:
                    errors.append(f"suspect_error:{s['slug']}:{e}")
                    s["suspect_set"] = False

    return {
        "scanned": len(results),
        "sessions": results,
        "recommendations": rec_counts,
        "current_session": current_dict,
        "errors": errors
    }
