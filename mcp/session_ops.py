#!/usr/bin/env python3
"""
Session / Event / Stats / Briefing / Maintenance operations.
Depends on db_core.py for connection management.
"""

import json
import time
from typing import Optional, Any
from datetime import datetime, timezone, timedelta

from db_core import (
    get_db, ensure_schema, get_db_path, new_id, now_iso,
    make_fingerprint, jaccard_similarity
)

# Session operations

def session_create(project_dir: Optional[str] = None,
                   date: Optional[str] = None,
                   time_val: Optional[str] = None,
                   slug: Optional[str] = None,
                   pid: Optional[int] = None,
                   token: Optional[str] = None) -> dict:
    """Create a new session record."""
    session_id = new_id()
    if date is None:
        date = datetime.now().strftime('%Y-%m-%d')
    if time_val is None:
        time_val = datetime.now().strftime('%H%M%S')
    if slug is None:
        slug = f"{date}_{time_val}"
    now = now_iso()
    with get_db(project_dir) as conn:
        conn.execute("""
            INSERT INTO sessions (id, date, time, slug, pid, status, start_time, token_used)
            VALUES (?, ?, ?, ?, ?, 'active', ?, ?)
        """, (session_id, date, time_val, slug, pid, now, token))
    return {"id": session_id, "slug": slug, "status": "active"}

def session_finalize(project_dir: Optional[str] = None,
                     session_id: Optional[str] = None,
                     summary: Optional[str] = None,
                     context_summary: Optional[str] = None,
                     exit_code: Optional[int] = None,
                     status: str = 'completed') -> dict:
    """Finalize a session on exit."""
    now = now_iso()
    with get_db(project_dir) as conn:
        if session_id is None:
            row = conn.execute(
                "SELECT id FROM sessions WHERE status='active' ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
            if row:
                session_id = row['id']
            else:
                return {"error": "No active session found"}

        # Calculate duration
        start = conn.execute(
            "SELECT start_time FROM sessions WHERE id=?", (session_id,)
        ).fetchone()
        duration_min = None
        if start and start['start_time']:
            try:
                start_dt = datetime.fromisoformat(start['start_time'])
                end_dt = datetime.fromisoformat(now)
                duration_min = int((end_dt - start_dt).total_seconds() / 60)
            except Exception:
                pass

        conn.execute("""
            UPDATE sessions SET
                status=?, summary=?, context_summary=?,
                end_time=?, exit_code=?, duration_min=?,
                updated_at=?
            WHERE id=?
        """, (status, summary, context_summary, now, exit_code,
              duration_min, now, session_id))
    return {"id": session_id, "status": status, "duration_min": duration_min}

def session_get(project_dir: Optional[str] = None,
                session_id: Optional[str] = None,
                slug: Optional[str] = None) -> Optional[dict]:
    """Get a session by ID or slug."""
    with get_db(project_dir) as conn:
        if session_id:
            row = conn.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
        elif slug:
            row = conn.execute("SELECT * FROM sessions WHERE slug=?", (slug,)).fetchone()
        else:
            row = conn.execute(
                "SELECT * FROM sessions ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
        return dict(row) if row else None

def session_list(project_dir: Optional[str] = None,
                 status: Optional[str] = None,
                 limit: int = 20, offset: int = 0) -> list:
    """List sessions with optional status filter."""
    with get_db(project_dir) as conn:
        if status:
            rows = conn.execute(
                "SELECT * FROM sessions WHERE status=? ORDER BY created_at DESC LIMIT ? OFFSET ?",
                (status, limit, offset)
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM sessions ORDER BY created_at DESC LIMIT ? OFFSET ?",
                (limit, offset)
            ).fetchall()
        return [dict(r) for r in rows]

def session_check_active(project_dir: Optional[str] = None) -> Optional[dict]:
    """Check if there's an active session (for bug#2 fix)."""
    with get_db(project_dir) as conn:
        row = conn.execute(
            "SELECT * FROM sessions WHERE status='active' ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
        return dict(row) if row else None

def session_mark_abandoned(project_dir: Optional[str] = None,
                           session_id: Optional[str] = None,
                           exclude_id: Optional[str] = None):
    """Mark CRASHED sessions as abandoned. Only acts when there are 2+ active sessions
    (the newest is the current session, older ones are crash residues).
    Returns the number of rows affected."""
    with get_db(project_dir) as conn:
        if session_id:
            cur = conn.execute("UPDATE sessions SET abandoned=1 WHERE id=?", (session_id,))
            return {"rowcount": cur.rowcount}

        # Count active sessions
        active_count = conn.execute(
            "SELECT count(*) FROM sessions WHERE status='active' AND abandoned=0"
        ).fetchone()[0]

        # If only 1 active session, it's the current one — don't touch it
        if active_count <= 1:
            return {"rowcount": 0, "active_count": active_count}

        # 2+ active = crash residues. Keep the newest (current), mark others.
        newest = conn.execute(
            "SELECT id FROM sessions WHERE status='active' AND abandoned=0 ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
        if newest and exclude_id:
            cur = conn.execute(
                "UPDATE sessions SET abandoned=1 WHERE status='active' AND abandoned=0 AND id != ?",
                (exclude_id,)
            )
        elif newest:
            cur = conn.execute(
                "UPDATE sessions SET abandoned=1 WHERE status='active' AND abandoned=0 AND id != ?",
                (newest[0],)
            )
        else:
            return {"rowcount": 0}
        return {"rowcount": cur.rowcount}

def session_events(project_dir: Optional[str] = None,
                   session_id: Optional[str] = None,
                   limit: int = 200) -> list:
    """Get all events for a session."""
    with get_db(project_dir) as conn:
        if session_id is None:
            session = conn.execute(
                "SELECT id FROM sessions ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
            session_id = session['id'] if session else None
        if session_id is None:
            return []
        rows = conn.execute(
            "SELECT * FROM events WHERE session_id=? ORDER BY id LIMIT ?",
            (session_id, limit)
        ).fetchall()
        return [dict(r) for r in rows]

def session_events_by_slug(project_dir: Optional[str] = None,
                           slug: str = "",
                           limit: int = 200) -> list:
    """Get all events for a session, looked up by slug."""
    with get_db(project_dir) as conn:
        session = conn.execute(
            "SELECT id FROM sessions WHERE slug=? ORDER BY created_at DESC LIMIT 1",
            (slug,)
        ).fetchone()
        if not session:
            return []
        rows = conn.execute(
            "SELECT timestamp, tool_name, tool_input_summary, file_path FROM events "
            "WHERE session_id=? ORDER BY id LIMIT ?",
            (session['id'], limit)
        ).fetchall()
        return [dict(r) for r in rows]

def session_compile_md(project_dir: Optional[str] = None,
                       slug: str = "") -> str:
    """Compile a complete session .md file from SQLite data (Phase C).
    Returns markdown string ready to write to the session file."""
    with get_db(project_dir) as conn:
        # Session record
        session = conn.execute(
            "SELECT * FROM sessions WHERE slug=? ORDER BY created_at DESC LIMIT 1",
            (slug,)
        ).fetchone()
        if not session:
            return ""

        # Events
        events = conn.execute(
            "SELECT timestamp, tool_name, tool_input_summary, file_path "
            "FROM events WHERE session_id=? ORDER BY id",
            (session['id'],)
        ).fetchall()

        # Build markdown
        lines = []
        lines.append(f"# {slug}")
        lines.append("")
        lines.append(f"<!-- token: {session['token_used'] or 'session-unknown'} -->")
        lines.append("")
        lines.append(f"**日期**: {session['date']}")
        lines.append(f"**摘要**: {session['summary'] or '（待填充）'}")
        lines.append(f"**PID**: {session['pid'] or '未知'}")
        lines.append(f"**开始时间**: {session['start_time'] or '未知'}")
        lines.append("")
        lines.append("---")
        lines.append("")

        # Auto info (from DB)
        lines.append("## 自动信息")
        lines.append("")
        if session['end_time']:
            lines.append(f"- **结束时间**: {session['end_time']}")
            lines.append(f"- **退出码**: {session['exit_code'] or '?'}")
            lines.append(f"- **时长**: {session['duration_min']} 分钟" if session['duration_min'] else "- **时长**: 未知")
            lines.append(f"- **状态**: {'⚠ 异常退出' if session['status'] == 'abandoned' else '✅ 正常结束'}")
        else:
            lines.append("（会话未正常结束）")
        lines.append("")

        # Tool call records
        lines.append("### 工具调用记录")
        lines.append("")
        if events:
            lines.append(f"共 {len(events)} 次：")
            lines.append("")
            for e in events:
                ts = e['timestamp'] or '??:??:??'
                tool = e['tool_name'] or '?'
                summary = (e['tool_input_summary'] or '-')[:80]
                fp = e['file_path']
                if fp:
                    lines.append(f"- {ts} {tool} `{fp}` {summary}")
                else:
                    lines.append(f"- {ts} {tool} {summary}")
        else:
            lines.append("（无工具调用记录）")
        lines.append("")

        # File changes (from events with file_path)
        changed_files = [e['file_path'] for e in events if e['file_path']]
        lines.append("### 文件变更")
        lines.append("")
        if changed_files:
            # deduplicate
            seen = set()
            unique_files = []
            for f in changed_files:
                if f not in seen:
                    seen.add(f)
                    unique_files.append(f)
            for f in unique_files[:30]:
                lines.append(f"- `{f}`")
            if len(unique_files) > 30:
                lines.append(f"- ... 及其他 {len(unique_files) - 30} 个文件")
        else:
            lines.append("（无文件变更记录）")

        lines.append("")
        lines.append("---")
        lines.append("")

        # AI-fillable sections (preserved from existing .md if present)
        lines.append("## 上下文")
        lines.append("")
        lines.append(session['context_summary'] or "（待填充）")
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append("## 任务")
        lines.append("")
        lines.append("（待填充）")

        return "\n".join(lines)

# Event operations

def event_log(project_dir: Optional[str] = None,
              session_id: Optional[str] = None,
              tool_name: str = "",
              tool_input_summary: Optional[str] = None,
              file_path: Optional[str] = None,
              exit_code: Optional[int] = None) -> dict:
    """Log a tool call event to the events table."""
    now = datetime.now().strftime('%H:%M:%S')
    with get_db(project_dir) as conn:
        if session_id is None:
            row = conn.execute(
                "SELECT id FROM sessions WHERE status='active' ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
            session_id = row['id'] if row else None
        if session_id is None:
            return {"error": "No active session found"}
        conn.execute("""
            INSERT INTO events (session_id, timestamp, tool_name, tool_input_summary, file_path, exit_code)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (session_id, now, tool_name, tool_input_summary, file_path, exit_code))
def stats_overview(project_dir: Optional[str] = None) -> dict:
    with get_db(project_dir) as conn:
        row = conn.execute("SELECT * FROM stats_overview").fetchone()
        if row:
            return dict(row)
        return {}

def session_stats(project_dir: Optional[str] = None) -> dict:
    """Get session counts by status (replaces session_index_read)."""
    with get_db(project_dir) as conn:
        total = conn.execute("SELECT COUNT(*) as c FROM sessions").fetchone()['c']
        complete = conn.execute(
            "SELECT COUNT(*) as c FROM sessions WHERE status='completed'"
        ).fetchone()['c']
        skeleton = conn.execute(
            "SELECT COUNT(*) as c FROM sessions WHERE status IN ('active','abandoned')"
        ).fetchone()['c']
        return {"total": total, "complete": complete, "skeleton": skeleton}

def session_find_status(project_dir: Optional[str] = None,
                        date: str = "",
                        time_val: str = "") -> str:
    """Find session status by date+time (replaces session_index_find).
    Returns 'complete', 'skeleton', or 'unknown'."""
    with get_db(project_dir) as conn:
        row = conn.execute(
            "SELECT status FROM sessions WHERE date=? AND time=? ORDER BY created_at DESC LIMIT 1",
            (date, time_val)
        ).fetchone()
        if not row:
            return "unknown"
        status = row['status']
        if status == 'completed':
            return "complete"
        elif status in ('active', 'abandoned'):
            return "skeleton"
        return "unknown"

# Briefing operations

def briefing_generate(project_dir: Optional[str] = None,
                      max_tokens: int = 500) -> str:
    """Generate a compact briefing from SQLite data for SessionStart injection."""
    with get_db(project_dir) as conn:
        sections = []

        # 1. Project identity
        prefs = {}
        for r in conn.execute("SELECT key, value FROM preferences WHERE category='project'").fetchall():
            prefs[r['key']] = r['value']
        if prefs:
            sections.append("Project: " + ", ".join(f"{k}={v}" for k, v in list(prefs.items())[:3]))

        # 2. Active decisions (top 3)
        decs = conn.execute(
            "SELECT title, status FROM decisions WHERE status='active' ORDER BY created_at DESC LIMIT 3"
        ).fetchall()
        if decs:
            lines = ["Active decisions:"]
            for d in decs:
                lines.append(f"- [{d['status']}] {d['title']}")
            sections.append("\n".join(lines))

        # 3. High-value patterns (top 2)
        pats = conn.execute(
            "SELECT title, category FROM patterns WHERE confidence > 0.7 ORDER BY hit_count DESC LIMIT 2"
        ).fetchall()
        if pats:
            lines = ["Key patterns:"]
            for p in pats:
                lines.append(f"- [{p['category']}] {p['title']}")
            sections.append("\n".join(lines))

        # 4. Recent work (last 3 completed sessions)
        sess = conn.execute(
            "SELECT slug, summary FROM sessions WHERE status='completed' AND summary IS NOT NULL "
            "ORDER BY date DESC, time DESC LIMIT 3"
        ).fetchall()
        if sess:
            lines = ["Recent sessions:"]
            for s in sess:
                summary = (s['summary'] or '')[:100]
                lines.append(f"- {s['slug']}: {summary}")
            sections.append("\n".join(lines))

        # 5. Stats pointer
        stats = stats_overview(project_dir)
        sections.append(
            f"Stats: {stats.get('total_sessions',0)} sessions, "
            f"{stats.get('total_memories',0)} memories, "
            f"{stats.get('active_decisions',0)} decisions"
        )

        briefing = "\n\n".join(sections)

        # Cache it
        conn.execute("DELETE FROM briefing_cache")
        conn.execute(
            "INSERT INTO briefing_cache (content, token_estimate, session_count, memory_count) VALUES (?,?,?,?)",
            (briefing, len(briefing.split()) // 2, len(sess), stats.get('total_memories', 0))
        )

    return briefing

def briefing_get(project_dir: Optional[str] = None) -> Optional[str]:
    with get_db(project_dir) as conn:
        row = conn.execute("SELECT content FROM briefing_cache ORDER BY generated_at DESC LIMIT 1").fetchone()
        return row['content'] if row else None

# Memory relations (graph)

def memory_relation_create(project_dir: Optional[str] = None,
                           source_id: str = "",
                           target_id: str = "",
                           relation_type: str = "relates_to",
                           weight: float = 1.0) -> dict:
    """Create a typed relation between two memories."""
    rel_id = new_id()
    with get_db(project_dir) as conn:
        try:
            conn.execute("""
                INSERT INTO memory_relations (id, source_id, target_id, relation_type, weight)
                VALUES (?,?,?,?,?)
            """, (rel_id, source_id, target_id, relation_type, weight))
        except Exception:
            return {"status": "duplicate", "source_id": source_id, "target_id": target_id}
    return {"id": rel_id, "status": "created"}

def memory_relations_get(project_dir: Optional[str] = None,
                         mem_id: str = "",
                         direction: str = "both",
                         max_depth: int = 2) -> list:
    """Get related memories via BFS graph traversal up to max_depth.
    direction: 'out' (source), 'in' (target), 'both'"""
    with get_db(project_dir) as conn:
        visited = set()
        result = []
        frontier = [(mem_id, 0)]

        while frontier:
            current, depth = frontier.pop(0)
            if current in visited or depth > max_depth:
                continue
            visited.add(current)

            if current != mem_id:  # Skip the origin node
                mem = conn.execute("SELECT * FROM memories WHERE id=?", (current,)).fetchone()
                if mem:
                    result.append(dict(mem) | {"_depth": depth})

            if depth < max_depth:
                if direction in ('out', 'both'):
                    edges = conn.execute(
                        "SELECT target_id FROM memory_relations WHERE source_id=?",
                        (current,)
                    ).fetchall()
                    for e in edges:
                        if e[0] not in visited:
                            frontier.append((e[0], depth + 1))

                if direction in ('in', 'both'):
                    edges = conn.execute(
                        "SELECT source_id FROM memory_relations WHERE target_id=?",
                        (current,)
                    ).fetchall()
                    for e in edges:
                        if e[0] not in visited:
                            frontier.append((e[0], depth + 1))

    return result

def memory_graph_get(project_dir: Optional[str] = None,
                     mem_id: str = "",
                     max_depth: int = 3) -> dict:
    """Get the full graph around a memory (nodes + edges)."""
    with get_db(project_dir) as conn:
        # Collect all related nodes via BFS
        visited = set()
        node_ids = set()
        edges = []
        frontier = [(mem_id, 0)]

        while frontier:
            current, depth = frontier.pop(0)
            if current in visited or depth > max_depth:
                continue
            visited.add(current)
            node_ids.add(current)

            if depth < max_depth:
                for row in conn.execute(
                    "SELECT * FROM memory_relations WHERE source_id=? OR target_id=?",
                    (current, current)
                ).fetchall():
                    edges.append(dict(row))
                    if row['source_id'] not in visited:
                        frontier.append((row['source_id'], depth + 1))
                    if row['target_id'] not in visited:
                        frontier.append((row['target_id'], depth + 1))

        # Fetch node details
        nodes = []
        for nid in node_ids:
            mem = conn.execute("SELECT id, type, content, confidence FROM memories WHERE id=?", (nid,)).fetchone()
            if mem:
                nodes.append(dict(mem))

    return {"nodes": nodes, "edges": edges, "center": mem_id}

# Maintenance operations

DECAY_CONFIG = {
    'pattern': None,
    'decision': None,
    'preference': None,
    'semantic': 30,
    'procedural': 60,
    'episodic': 7,
}

def decay_run(project_dir: Optional[str] = None) -> dict:
    """Run type-aware decay on memories."""
    now = datetime.now(timezone.utc)
    results = {'archived': 0, 'deleted': 0}
    with get_db(project_dir) as conn:
        for mem_type, ttl_days in DECAY_CONFIG.items():
            if ttl_days is None:
                continue
            cutoff = (now - timedelta(days=ttl_days)).isoformat()
            # Archive: still searchable but not in briefing
            archived = conn.execute("""
                UPDATE memories SET expires_at=?
                WHERE type=? AND expires_at IS NULL AND updated_at <?
            """, (now.isoformat(), mem_type, cutoff)).rowcount
            results['archived'] += archived

            # Delete expired beyond twice the TTL
            deep_cutoff = (now - timedelta(days=ttl_days * 3)).isoformat()
            deleted = conn.execute("""
                DELETE FROM memories
                WHERE type=? AND expires_at IS NOT NULL AND expires_at <?
            """, (mem_type, deep_cutoff)).rowcount
            results['deleted'] += deleted

        conn.execute("""
            INSERT INTO maintenance_log (operation, items_affected, details)
            VALUES ('decay_run', ?, ?)
        """, (results['archived'] + results['deleted'], json.dumps(results)))
    return results

def dedup_run(project_dir: Optional[str] = None, dry_run: bool = False) -> list:
    """Run batch dedup on memories."""
    findings = []
    with get_db(project_dir) as conn:
        # Get all same-type memory groups with >1 entry
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
                    if sim > 0.85:
                        findings.append({
                            'type': g['type'],
                            'id_a': rows[i]['id'],
                            'id_b': rows[j]['id'],
                            'similarity': round(sim, 3),
                        })
                        if not dry_run and sim > 0.95:
                            conn.execute(
                                "UPDATE memories SET supersedes=?, updated_at=? WHERE id=?",
                                (rows[i]['id'], now_iso(), rows[j]['id'])
                            )
        if not dry_run:
            conn.execute("""
                INSERT INTO maintenance_log (operation, items_affected, details)
                VALUES ('dedup_run', ?, ?)
            """, (len(findings), json.dumps(findings)))
    return findings
