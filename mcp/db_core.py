#!/usr/bin/env python3
"""
Claude Code Context Manager - MCP Database Layer
SQLite schema definition and all CRUD operations.
Version: 1.0.0
"""

import sqlite3
import json
import hashlib
import uuid
import os
import time
from datetime import datetime, timezone
from contextlib import contextmanager
from typing import Optional, Any

# Database path

DEFAULT_DB_NAME = "memory.db"

def get_db_path(project_dir: Optional[str] = None) -> str:
    if project_dir is None:
        project_dir = os.getcwd()
    context_dir = os.path.join(project_dir, '.claude', 'context')
    os.makedirs(context_dir, exist_ok=True)
    return os.path.join(context_dir, DEFAULT_DB_NAME)

# Connection management

@contextmanager
def get_db(project_dir: Optional[str] = None):
    db_path = get_db_path(project_dir)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=5000")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

# Schema initialization

SCHEMA_VERSION = 2


def _migrate_v4(conn: sqlite3.Connection):
    """Idempotent: add v4.0 columns if they don't exist."""
    cols = {r[1] for r in conn.execute("PRAGMA table_info(events)").fetchall()}

    if 'stderr_summary' not in cols:
        conn.execute("ALTER TABLE events ADD COLUMN stderr_summary TEXT")
    if 'duration_ms' not in cols:
        conn.execute("ALTER TABLE events ADD COLUMN duration_ms INTEGER")

    # Add exit_code index if not present (idempotent via IF NOT EXISTS)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_events_exit_code ON events(exit_code)"
    )


def init_schema(conn: sqlite3.Connection):
    """Initialize database schema (idempotent)."""
    conn.executescript("""
        -- Version tracking
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY,
            applied_at TEXT DEFAULT (datetime('now'))
        );

        -- Sessions table
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            date TEXT NOT NULL,
            time TEXT NOT NULL,
            slug TEXT NOT NULL UNIQUE,
            pid INTEGER,
            status TEXT DEFAULT 'active',
            summary TEXT,
            context_summary TEXT,
            start_time TEXT,
            end_time TEXT,
            duration_min INTEGER,
            exit_code INTEGER,
            token_used INTEGER,
            abandoned INTEGER DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
        CREATE INDEX IF NOT EXISTS idx_sessions_date ON sessions(date);
        CREATE INDEX IF NOT EXISTS idx_sessions_slug ON sessions(slug);

        -- Memories table
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL CHECK(type IN (
                'episodic','semantic','procedural','pattern','decision','preference'
            )),
            content TEXT NOT NULL,
            source_session_id TEXT REFERENCES sessions(id),
            confidence REAL DEFAULT 1.0,
            importance REAL DEFAULT 0.5,
            access_count INTEGER DEFAULT 0,
            hit_count INTEGER DEFAULT 0,
            tags TEXT DEFAULT '[]',
            metadata TEXT DEFAULT '{}',
            supersedes TEXT,
            merged_from TEXT,
            fingerprint TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now')),
            expires_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_memories_type ON memories(type);
        CREATE INDEX IF NOT EXISTS idx_memories_session ON memories(source_session_id);
        CREATE INDEX IF NOT EXISTS idx_memories_fingerprint ON memories(fingerprint);

        -- Events table (replaces .log files)
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            timestamp TEXT NOT NULL,
            tool_name TEXT NOT NULL,
            tool_input_summary TEXT,
            file_path TEXT,
            exit_code INTEGER,
            stderr_summary TEXT,
            duration_ms INTEGER,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id);
        CREATE INDEX IF NOT EXISTS idx_events_tool ON events(tool_name);
        CREATE INDEX IF NOT EXISTS idx_events_exit_code ON events(exit_code);

        -- Decisions table
        CREATE TABLE IF NOT EXISTS decisions (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            context TEXT,
            rationale TEXT,
            alternatives TEXT DEFAULT '[]',
            status TEXT DEFAULT 'active',
            superseded_by TEXT,
            session_id TEXT REFERENCES sessions(id),
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_decisions_status ON decisions(status);

        -- Patterns table
        CREATE TABLE IF NOT EXISTS patterns (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            description TEXT,
            category TEXT DEFAULT 'convention',
            confidence REAL DEFAULT 0.5,
            hit_count INTEGER DEFAULT 0,
            source_session_ids TEXT DEFAULT '[]',
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_patterns_category ON patterns(category);

        -- Preferences table
        CREATE TABLE IF NOT EXISTS preferences (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            category TEXT,
            session_id TEXT REFERENCES sessions(id),
            updated_at TEXT DEFAULT (datetime('now'))
        );

        -- Memory relations graph
        CREATE TABLE IF NOT EXISTS memory_relations (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL REFERENCES memories(id),
            target_id TEXT NOT NULL REFERENCES memories(id),
            relation_type TEXT NOT NULL CHECK(relation_type IN (
                'relates_to','depends_on','contradicts','extends','implements','derived_from'
            )),
            weight REAL DEFAULT 1.0,
            created_at TEXT DEFAULT (datetime('now')),
            UNIQUE(source_id, target_id, relation_type)
        );
        CREATE INDEX IF NOT EXISTS idx_rel_source ON memory_relations(source_id);
        CREATE INDEX IF NOT EXISTS idx_rel_target ON memory_relations(target_id);

        -- FTS5 virtual table for full-text search on memories
        CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
            content, tags,
            content='memories',
            content_rowid='rowid'
        );

        -- Triggers to keep FTS in sync
        CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
            INSERT INTO memories_fts(rowid, content, tags) VALUES (new.rowid, new.content, new.tags);
        END;

        CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
            INSERT INTO memories_fts(memories_fts, rowid, content, tags) VALUES('delete', old.rowid, old.content, old.tags);
        END;

        CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
            INSERT INTO memories_fts(memories_fts, rowid, content, tags) VALUES('delete', old.rowid, old.content, old.tags);
            INSERT INTO memories_fts(rowid, content, tags) VALUES (new.rowid, new.content, new.tags);
        END;

        -- Briefing cache table
        CREATE TABLE IF NOT EXISTS briefing_cache (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            content TEXT NOT NULL,
            generated_at TEXT DEFAULT (datetime('now')),
            token_estimate INTEGER DEFAULT 0,
            session_count INTEGER DEFAULT 0,
            memory_count INTEGER DEFAULT 0
        );

        -- Dedup log
        CREATE TABLE IF NOT EXISTS dedup_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            action TEXT NOT NULL,
            original_id TEXT,
            new_id TEXT,
            similarity REAL,
            reason TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );

        -- Maintenance log
        CREATE TABLE IF NOT EXISTS maintenance_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            operation TEXT NOT NULL,
            items_affected INTEGER DEFAULT 0,
            details TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );

        -- v4.0: Behavior profile (quantitative analysis results)
        CREATE TABLE IF NOT EXISTS behavior_profile (
            dimension TEXT NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            confidence REAL DEFAULT 1.0,
            source TEXT DEFAULT 'quantitative',
            updated_at TEXT DEFAULT (datetime('now')),
            PRIMARY KEY (dimension, key)
        );

        -- v4.0: Analysis runs (audit trail)
        CREATE TABLE IF NOT EXISTS analysis_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            triggered_by TEXT DEFAULT 'scheduler',
            sessions_analyzed INTEGER DEFAULT 0,
            events_analyzed INTEGER DEFAULT 0,
            results_summary TEXT,
            duration_ms INTEGER,
            created_at TEXT DEFAULT (datetime('now'))
        );

        -- v4.5: Task persistence (cross-session task states)
        CREATE TABLE IF NOT EXISTS task_states (
            task_id TEXT PRIMARY KEY,
            plan_slug TEXT NOT NULL,
            subject TEXT NOT NULL,
            description TEXT,
            status TEXT DEFAULT 'pending' CHECK(status IN ('pending','in_progress','completed','abandoned')),
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now')),
            completed_at TEXT,
            source_session_id TEXT REFERENCES sessions(id)
        );
        CREATE INDEX IF NOT EXISTS idx_task_states_plan ON task_states(plan_slug);
        CREATE INDEX IF NOT EXISTS idx_task_states_status ON task_states(status);
        CREATE INDEX IF NOT EXISTS idx_behavior_profile_dim ON behavior_profile(dimension);
    """)

    # Record schema version
    existing = conn.execute(
        "SELECT version FROM schema_version WHERE version = ?", (SCHEMA_VERSION,)
    ).fetchone()
    if not existing:
        conn.execute(
            "INSERT OR REPLACE INTO schema_version(version) VALUES (?)",
            (SCHEMA_VERSION,)
        )

    # ── v4.0 migrations: add columns if missing (idempotent) ──
    _migrate_v4(conn)

    # Create stats view
    conn.execute("""
        CREATE VIEW IF NOT EXISTS stats_overview AS
        SELECT
            (SELECT count(*) FROM sessions) AS total_sessions,
            (SELECT count(*) FROM sessions WHERE status='completed') AS completed,
            (SELECT count(*) FROM sessions WHERE status='skeleton') AS skeletons,
            (SELECT count(*) FROM sessions WHERE status='crashed') AS crashed,
            (SELECT count(*) FROM memories) AS total_memories,
            (SELECT count(*) FROM decisions WHERE status='active') AS active_decisions,
            (SELECT count(*) FROM patterns) AS patterns,
            (SELECT count(*) FROM events) AS total_events
    """)

def ensure_schema(project_dir: Optional[str] = None):
    """Ensure DB exists and schema is up to date."""
    db_path = get_db_path(project_dir)
    is_new = not os.path.exists(db_path)
    with get_db(project_dir) as conn:
        init_schema(conn)
    return {"db_path": db_path, "is_new": is_new}

# Utility functions

def new_id() -> str:
    return str(uuid.uuid4())

def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

def make_fingerprint(content: str) -> str:
    return hashlib.sha256(content[:512].encode('utf-8')).hexdigest()

def tokenize_simple(text: str) -> set:
    """Simple word tokenizer for Jaccard similarity."""
    stopwords = {'the','a','an','is','are','was','were','with','for','to',
                 'in','on','of','and','or','not','it','its','this','that',
                 'be','been','being','have','has','had','do','does','did',
                 'will','would','shall','should','may','might','must','can'}
    import re
    words = re.findall(r'[a-zA-Z0-9_]+', text.lower())
    return {w for w in words if w not in stopwords and len(w) > 1}

def jaccard_similarity(text_a: str, text_b: str) -> float:
    tokens_a = tokenize_simple(text_a)
    tokens_b = tokenize_simple(text_b)
    if not tokens_a or not tokens_b:
        return 0.0
    intersection = tokens_a & tokens_b
    union = tokens_a | tokens_b
    return len(intersection) / len(union) if union else 0.0
