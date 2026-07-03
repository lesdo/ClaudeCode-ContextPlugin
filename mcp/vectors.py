#!/usr/bin/env python3
"""
Lightweight vector embeddings for memory search.
Uses pure-Python TF-IDF + random projection (no external dependencies).
Falls back to FTS5-only search when sqlite-vec is unavailable.
"""

import re
import math
import hashlib
import struct
import os
from collections import Counter
from typing import Optional

# Try to load sqlite-vec
try:
    import sqlite_vec
    HAS_VEC = True
except ImportError:
    HAS_VEC = False

# Vocabulary cache per project
_vocab_cache = {}  # db_path -> {word: index}
_idf_cache = {}    # db_path -> {word: idf}


def tokenize(text: str) -> list:
    """Simple tokenizer: lowercase + split on non-alphanumeric."""
    return re.findall(r'[a-zA-Z0-9_一-鿿]+', text.lower())


def build_vocab(texts: list, db_path: str, max_features: int = 384) -> dict:
    """Build a vocabulary from a corpus of texts, capped at max_features."""
    df = Counter()
    for text in texts:
        tokens = set(tokenize(text))
        for t in tokens:
            df[t] += 1

    n = len(texts) or 1
    # Compute IDF for each term
    idf = {}
    for term, count in df.most_common(max_features):
        idf[term] = math.log((n + 1) / (count + 1)) + 1.0

    # Build vocab (term -> index in vector)
    vocab = {term: i for i, term in enumerate(idf.keys())}

    _vocab_cache[db_path] = vocab
    _idf_cache[db_path] = idf
    return vocab


def encode(text: str, db_path: str, dim: int = 384) -> Optional[bytes]:
    """Encode text to a float vector blob for sqlite-vec.
    Uses TF-IDF weighted bag-of-words, padded/truncated to dim.
    Returns None if no vocab exists."""
    vocab = _vocab_cache.get(db_path)
    idf = _idf_cache.get(db_path)

    if not vocab:
        return None

    tokens = tokenize(text)
    vec = [0.0] * dim
    for t in tokens:
        if t in vocab and vocab[t] < dim:
            vec[vocab[t]] = idf.get(t, 1.0)

    # Normalize to unit vector
    norm = math.sqrt(sum(v * v for v in vec))
    if norm > 0:
        vec = [v / norm for v in vec]

    return struct.pack(f'{dim}f', *vec)


def update_vocab(texts: list, db_path: str, dim: int = 384):
    """Update vocabulary with new texts (incremental)."""
    build_vocab(texts, db_path, dim)


def ensure_vec_table(conn, dim: int = 384):
    """Create vec_memories virtual table if it doesn't exist."""
    if not HAS_VEC:
        return False
    try:
        conn.enable_load_extension(True)
        sqlite_vec.load(conn)
        conn.execute(f"""
            CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories USING vec0(
                embedding float[{dim}]
            )
        """)
        return True
    except Exception:
        return False


def _ensure_vec_loaded(conn):
    """Ensure sqlite-vec is loaded on this connection."""
    if not HAS_VEC:
        return False
    try:
        sqlite_vec.load(conn)
        return True
    except Exception:
        return False

def index_memory(conn, memory_rowid: int, content: str, db_path: str, dim: int = 384):
    """Index a memory's embedding into vec_memories."""
    if not HAS_VEC:
        return

    blob = encode(content, db_path, dim)
    if blob is None:
        return

    if not _ensure_vec_loaded(conn):
        return

    try:
        # Delete old embedding if exists (by rowid match)
        conn.execute("DELETE FROM vec_memories WHERE rowid = ?", (memory_rowid,))
        conn.execute("INSERT INTO vec_memories (rowid, embedding) VALUES (?, ?)",
                     (memory_rowid, blob))
    except Exception:
        pass  # vec_memories may not exist yet


def vector_search(conn, query: str, db_path: str, top_k: int = 20) -> list:
    """Search memories by vector similarity. Returns list of (rowid, distance)."""
    if not HAS_VEC:
        return []

    blob = encode(query, db_path)
    if blob is None:
        return []

    if not _ensure_vec_loaded(conn):
        return []

    try:
        rows = conn.execute(
            "SELECT rowid, distance FROM vec_memories WHERE embedding MATCH ? ORDER BY distance LIMIT ?",
            (blob, top_k)
        ).fetchall()
        return [(r[0], r[1]) for r in rows]
    except Exception:
        return []


def hybrid_search(conn, query: str, db_path: str, top_k: int = 20) -> list:
    """
    Hybrid search: FTS5 (BM25) + vector (cosine) -> Reciprocal Rank Fusion.
    Falls back to FTS5-only if vector search unavailable.
    Returns list of memory dicts ranked by fused score.
    """
    # Auto-convert multi-word queries to OR for better FTS5 recall
    fts_query = query
    if ' OR ' not in query and ' AND ' not in query and ' NOT ' not in query:
        terms = query.split()
        if len(terms) > 1:
            fts_query = ' OR '.join(terms)

    # FTS5 search
    try:
        fts_rows = conn.execute("""
            SELECT rowid, rank FROM memories_fts
            WHERE memories_fts MATCH ?
            ORDER BY rank LIMIT ?
        """, (fts_query, top_k * 2)).fetchall()
    except Exception:
        fts_rows = []

    # Build FTS rank map
    fts_ranks = {}
    for i, (rowid, rank) in enumerate(fts_rows):
        fts_ranks[rowid] = i + 1  # 1-indexed rank

    # Vector search
    vec_rows = vector_search(conn, query, db_path, top_k * 2)
    vec_ranks = {}
    for i, (rowid, distance) in enumerate(vec_rows):
        vec_ranks[rowid] = i + 1  # 1-indexed rank

    # Reciprocal Rank Fusion (k=60, standard RRF constant)
    K = 60
    scores = {}
    all_rowids = set(fts_ranks.keys()) | set(vec_ranks.keys())

    for rowid in all_rowids:
        score = 0.0
        if rowid in fts_ranks:
            score += 1.0 / (K + fts_ranks[rowid])
        if rowid in vec_ranks:
            score += 1.0 / (K + vec_ranks[rowid])
        scores[rowid] = score

    # Sort by fused score
    ranked = sorted(scores.items(), key=lambda x: x[1], reverse=True)[:top_k]

    if not ranked:
        return []

    # Fetch full memory rows
    rowids = [r[0] for r in ranked]
    placeholders = ','.join('?' * len(rowids))
    rows = conn.execute(
        f"SELECT rowid, * FROM memories WHERE rowid IN ({placeholders})",
        rowids
    ).fetchall()

    # Map back scores
    score_map = dict(ranked)
    result = []
    for r in rows:
        d = dict(r)
        d['_hybrid_score'] = round(score_map.get(r['rowid'], 0), 4)
        result.append(d)

    result.sort(key=lambda x: x['_hybrid_score'], reverse=True)
    return result


def build_initial_vocab(conn, db_path: str, dim: int = 384):
    """Build vocabulary from all existing memories and index them."""
    rows = conn.execute("SELECT rowid, content FROM memories").fetchall()
    if not rows:
        return

    texts = [r[1] for r in rows]
    build_vocab(texts, db_path, dim)

    ensure_vec_table(conn, dim)

    for rowid, content in rows:
        index_memory(conn, rowid, content, db_path, dim)

    conn.commit()
    return len(rows)
