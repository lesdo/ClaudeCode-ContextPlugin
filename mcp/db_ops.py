#!/usr/bin/env python3
"""
CRUD operations for all tables.
Depends on db_core.py for connection management and utilities.
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
    return {"logged": True, "session_id": session_id, "tool": tool_name}

# Memory operations

def memory_store(project_dir: Optional[str] = None,
                 content: str = "",
                 mem_type: str = 'semantic',
                 session_id: Optional[str] = None,
                 confidence: float = 1.0,
                 importance: float = 0.5,
                 tags: Optional[list] = None,
                 metadata: Optional[dict] = None,
                 auto_dedup: bool = True) -> dict:
    """Store a memory with auto-dedup."""
    mem_id = new_id()
    fp = make_fingerprint(content)
    tags_json = json.dumps(tags or [], ensure_ascii=False)
    meta_json = json.dumps(metadata or {}, ensure_ascii=False)
    now = now_iso()

    with get_db(project_dir) as conn:
        if auto_dedup:
            # Exact fingerprint check
            existing = conn.execute(
                "SELECT id, hit_count FROM memories WHERE fingerprint=? AND type=?",
                (fp, mem_type)
            ).fetchone()
            if existing:
                conn.execute(
                    "UPDATE memories SET hit_count=hit_count+1, updated_at=? WHERE id=?",
                    (now, existing['id'])
                )
                conn.execute("""
                    INSERT INTO dedup_log (action, original_id, new_id, similarity, reason)
                    VALUES ('exact_skip', ?, ?, 1.0, 'exact fingerprint match')
                """, (existing['id'], mem_id))
                return {"id": existing['id'], "status": "deduped_exact",
                        "hit_count": existing['hit_count'] + 1}

            # Jaccard similarity check against last 10 of same type
            recent = conn.execute(
                "SELECT id, content FROM memories WHERE type=? ORDER BY created_at DESC LIMIT 10",
                (mem_type,)
            ).fetchall()
            for r in recent:
                sim = jaccard_similarity(content, r['content'])
                if sim > 0.85:
                    conn.execute("""
                        INSERT INTO dedup_log (action, original_id, new_id, similarity, reason)
                        VALUES ('near_duplicate', ?, ?, ?, 'jaccard > 0.85')
                    """, (r['id'], mem_id, sim))
                    if sim > 0.95:
                        # Supersede old
                        conn.execute(
                            "UPDATE memories SET supersedes=?, updated_at=? WHERE id=?",
                            (r['id'], now, mem_id)
                        )
                    return {"id": mem_id, "status": "near_duplicate",
                            "similar_to": r['id'], "similarity": round(sim, 3)}

        conn.execute("""
            INSERT INTO memories (id, type, content, source_session_id,
                   confidence, importance, tags, metadata, fingerprint, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (mem_id, mem_type, content, session_id, confidence, importance,
              tags_json, meta_json, fp, now))

        # Auto-index into vector store
        memory_rowid = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
        try:
            from vectors import index_memory
            index_memory(conn, memory_rowid, content, get_db_path(project_dir))
        except Exception:
            pass  # Vector indexing is best-effort

    return {"id": mem_id, "status": "stored"}

def memory_search(project_dir: Optional[str] = None,
                  query: str = "",
                  mem_type: Optional[str] = None,
                  tags: Optional[list] = None,
                  limit: int = 20) -> list:
    """FTS5 full-text search across memories."""
    # Auto-convert multi-word to OR for better recall
    fts_query = query
    if query and ' OR ' not in query and ' AND ' not in query and ' NOT ' not in query:
        terms = query.split()
        if len(terms) > 1:
            fts_query = ' OR '.join(terms)

    with get_db(project_dir) as conn:
        conditions = []
        params = []
        if query:
            conditions.append("memories_fts MATCH ?")
            params.append(fts_query)
        if mem_type:
            conditions.append("memories.type = ?")
            params.append(mem_type)
        if tags:
            tag_conds = []
            for t in tags:
                tag_conds.append("memories.tags LIKE ?")
                params.append(f'%{t}%')
            conditions.append(f"({' OR '.join(tag_conds)})")

        where = " AND ".join(conditions) if conditions else "1=1"
        sql = f"""
            SELECT memories.* FROM memories
            JOIN memories_fts ON memories.rowid = memories_fts.rowid
            WHERE {where}
            ORDER BY rank
            LIMIT ?
        """
        params.append(limit)
        rows = conn.execute(sql, params).fetchall()
        return [dict(r) for r in rows]

def memory_get(project_dir: Optional[str] = None, mem_id: str = "") -> Optional[dict]:
    """Get a memory by ID and increment access_count."""
    with get_db(project_dir) as conn:
        conn.execute(
            "UPDATE memories SET access_count=access_count+1, updated_at=? WHERE id=?",
            (now_iso(), mem_id)
        )
        row = conn.execute("SELECT * FROM memories WHERE id=?", (mem_id,)).fetchone()
        return dict(row) if row else None

def memory_update(project_dir: Optional[str] = None,
                  mem_id: str = "",
                  content: Optional[str] = None,
                  confidence: Optional[float] = None,
                  importance: Optional[float] = None,
                  tags: Optional[list] = None,
                  metadata: Optional[dict] = None) -> dict:
    """Update a memory."""
    now = now_iso()
    with get_db(project_dir) as conn:
        updates = ["updated_at = ?"]
        params = [now]
        if content is not None:
            updates.append("content = ?")
            params.append(content)
            updates.append("fingerprint = ?")
            params.append(make_fingerprint(content))
        if confidence is not None:
            updates.append("confidence = ?")
            params.append(confidence)
        if importance is not None:
            updates.append("importance = ?")
            params.append(importance)
        if tags is not None:
            updates.append("tags = ?")
            params.append(json.dumps(tags, ensure_ascii=False))
        if metadata is not None:
            updates.append("metadata = ?")
            params.append(json.dumps(metadata, ensure_ascii=False))
        params.append(mem_id)
        conn.execute(f"UPDATE memories SET {', '.join(updates)} WHERE id=?", params)
    return {"id": mem_id, "status": "updated"}

def memory_delete(project_dir: Optional[str] = None, mem_id: str = "") -> dict:
    with get_db(project_dir) as conn:
        conn.execute("DELETE FROM memories WHERE id=?", (mem_id,))
    return {"id": mem_id, "status": "deleted"}

def memory_list(project_dir: Optional[str] = None,
                mem_type: Optional[str] = None,
                limit: int = 50, offset: int = 0) -> list:
    with get_db(project_dir) as conn:
        if mem_type:
            rows = conn.execute(
                "SELECT * FROM memories WHERE type=? ORDER BY created_at DESC LIMIT ? OFFSET ?",
                (mem_type, limit, offset)
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM memories ORDER BY created_at DESC LIMIT ? OFFSET ?",
                (limit, offset)
            ).fetchall()
        return [dict(r) for r in rows]

def memory_hybrid_search(project_dir: Optional[str] = None,
                         query: str = "",
                         top_k: int = 20) -> list:
    """Hybrid search: FTS5 + vector -> RRF fusion."""
    db_path = get_db_path(project_dir)
    with get_db(project_dir) as conn:
        try:
            from vectors import hybrid_search
            return hybrid_search(conn, query, db_path, top_k)
        except Exception:
            return memory_search(project_dir, query=query, limit=top_k)

def memory_reindex_vectors(project_dir: Optional[str] = None) -> dict:
    """Rebuild vocabulary and re-index all memories into vector store."""
    db_path = get_db_path(project_dir)
    with get_db(project_dir) as conn:
        try:
            from vectors import build_initial_vocab
            count = build_initial_vocab(conn, db_path)
            return {"indexed": count}
        except Exception as e:
            return {"error": str(e)}

# Decision operations

def decision_record(project_dir: Optional[str] = None,
                    title: str = "",
                    context: Optional[str] = None,
                    rationale: Optional[str] = None,
                    alternatives: Optional[list] = None,
                    session_id: Optional[str] = None) -> dict:
    dec_id = new_id()
    alts_json = json.dumps(alternatives or [], ensure_ascii=False)
    with get_db(project_dir) as conn:
        conn.execute("""
            INSERT INTO decisions (id, title, context, rationale, alternatives, session_id)
            VALUES (?,?,?,?,?,?)
        """, (dec_id, title, context, rationale, alts_json, session_id))
    return {"id": dec_id, "title": title}

def decision_list(project_dir: Optional[str] = None,
                  status: str = 'active',
                  limit: int = 20) -> list:
    with get_db(project_dir) as conn:
        rows = conn.execute(
            "SELECT * FROM decisions WHERE status=? ORDER BY created_at DESC LIMIT ?",
            (status, limit)
        ).fetchall()
        return [dict(r) for r in rows]

# Pattern operations

def pattern_register(project_dir: Optional[str] = None,
                     title: str = "",
                     description: Optional[str] = None,
                     category: str = 'convention',
                     confidence: float = 0.5,
                     session_id: Optional[str] = None) -> dict:
    pat_id = new_id()
    with get_db(project_dir) as conn:
        conn.execute("""
            INSERT INTO patterns (id, title, description, category, confidence, source_session_ids)
            VALUES (?,?,?,?,?,?)
        """, (pat_id, title, description, category, confidence,
              json.dumps([session_id] if session_id else [])))
    return {"id": pat_id, "title": title}

def pattern_list(project_dir: Optional[str] = None,
                 category: Optional[str] = None,
                 limit: int = 20) -> list:
    with get_db(project_dir) as conn:
        if category:
            rows = conn.execute(
                "SELECT * FROM patterns WHERE category=? ORDER BY hit_count DESC LIMIT ?",
                (category, limit)
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM patterns ORDER BY hit_count DESC LIMIT ?",
                (limit,)
            ).fetchall()
        return [dict(r) for r in rows]

# Preference operations

def preference_get(project_dir: Optional[str] = None, key: str = "") -> Optional[str]:
    with get_db(project_dir) as conn:
        row = conn.execute("SELECT value FROM preferences WHERE key=?", (key,)).fetchone()
        return row['value'] if row else None

def preference_set(project_dir: Optional[str] = None,
                   key: str = "",
                   value: str = "",
                   category: Optional[str] = None,
                   session_id: Optional[str] = None) -> dict:
    now = now_iso()
    with get_db(project_dir) as conn:
        conn.execute("""
            INSERT OR REPLACE INTO preferences (key, value, category, session_id, updated_at)
            VALUES (?,?,?,?,?)
        """, (key, value, category, session_id, now))
    return {"key": key, "status": "saved"}

# Stats operations

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
