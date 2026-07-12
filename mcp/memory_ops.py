#!/usr/bin/env python3
"""
Memory / Decision / Pattern / Preference operations.
Depends on db_core.py for connection management and vectors.py for hybrid search.
"""

import json
import os
import time
from typing import Optional, Any
from datetime import datetime, timezone, timedelta

from db_core import (
    get_db, ensure_schema, get_db_path, new_id, now_iso,
    make_fingerprint, jaccard_similarity
)

# ── Memory relations (graph) ──

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
        except Exception as e:
            return {"status": "error", "reason": str(e)[:200]}
    return {"id": rel_id, "status": "created"}

def memory_relations_get(project_dir: Optional[str] = None,
                         mem_id: str = "",
                         direction: str = "both",
                         max_depth: int = 2) -> list:
    """Get related memories via BFS graph traversal up to max_depth."""
    with get_db(project_dir) as conn:
        visited = set()
        result = []
        frontier = [(mem_id, 0)]

        while frontier:
            current, depth = frontier.pop(0)
            if current in visited or depth > max_depth:
                continue
            visited.add(current)

            if current != mem_id:
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

        nodes = []
        for nid in node_ids:
            mem = conn.execute("SELECT id, type, content, confidence FROM memories WHERE id=?", (nid,)).fetchone()
            if mem:
                nodes.append(dict(mem))

    return {"nodes": nodes, "edges": edges, "center": mem_id}

# ax4: Jaccard thresholds configurable via env vars
def _jaccard_near_dup():
    return float(os.environ.get('CP_JACCARD_NEAR_DUP', '0.85'))

def _jaccard_supersede():
    return float(os.environ.get('CP_JACCARD_SUPERSEDE', '0.95'))

def _jaccard_window():
    return int(os.environ.get('CP_JACCARD_WINDOW', '10'))

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

            # Jaccard similarity check against recent memories of same type
            window = _jaccard_window()
            near_dup = _jaccard_near_dup()
            supersede = _jaccard_supersede()
            recent = conn.execute(
                "SELECT id, content FROM memories WHERE type=? ORDER BY created_at DESC LIMIT ?",
                (mem_type, window)
            ).fetchall()
            for r in recent:
                sim = jaccard_similarity(content, r['content'])
                if sim > near_dup:
                    conn.execute("""
                        INSERT INTO dedup_log (action, original_id, new_id, similarity, reason)
                        VALUES ('near_duplicate', ?, ?, ?, ?)
                    """, (r['id'], mem_id, sim, f'jaccard > {near_dup}'))
                    if sim > supersede:
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

        # Auto-index into vector store (best-effort, log failures)
        memory_rowid = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
        try:
            from vectors import index_memory
            index_memory(conn, memory_rowid, content, get_db_path(project_dir))
        except Exception as e:
            conn.execute("""
                INSERT INTO maintenance_log (operation, items_affected, details)
                VALUES ('vector_index_error', 1, ?)
            """, (json.dumps({'mem_id': mem_id, 'error': str(e)}),))

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

