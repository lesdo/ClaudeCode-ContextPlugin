#!/usr/bin/env python3
"""
Migrate existing flat-file session data to SQLite.
Scans .md and .log files, imports into the new database schema.
Idempotent — skips already-imported sessions.

Usage:
  python migrate.py [project_dir]           # Full migration
  python migrate.py [project_dir] --dry-run # Preview only
  python migrate.py [project_dir] --verify  # Verify counts match .session-index
"""

import sys
import os
import re
import json
import sqlite3
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from db_core import ensure_schema, get_db_path, new_id, now_iso
from db_ops import session_create, session_finalize, event_log, memory_store

# Session file patterns
RE_FILENAME = re.compile(r'^(\d{4}-\d{2}-\d{2})_(.+)\.(md|log)$')
RE_TOKEN = re.compile(r'<!-- token: session-(\d+)-(\d+)-(\d+) -->')
RE_SUMMARY = re.compile(r'\*\*摘要\*\*: (.+)')
RE_START_TIME = re.compile(r'\*\*开始时间\*\*: (.+)')
RE_PID = re.compile(r'\*\*PID\*\*: (\d+)')
RE_HEADER_DATE = re.compile(r'^# (\d{4}-\d{2}-\d{2}_\d{4})')
RE_AUTO_END_TIME = re.compile(r'\*\*结束时间\*\*: (.+)')
RE_AUTO_EXIT_CODE = re.compile(r'\*\*退出码\*\*: (.+)')
RE_AUTO_DURATION = re.compile(r'\*\*时长\*\*: (.+)')

# Log line pattern: "- HH:MM:SS ToolName detail..."
RE_LOG_LINE = re.compile(r'^- (\d{2}:\d{2}:\d{2}) (\S+)\s*(.*)')

def parse_md_file(filepath: str) -> dict:
    """Parse a session .md file and extract metadata."""
    info = {'status': 'skeleton'}
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

        # Token
        m = RE_TOKEN.search(content)
        if m:
            info['pid'] = int(m.group(1))
            info['token'] = m.group(0).strip('<!-- ').strip(' -->')

        # Summary
        m = RE_SUMMARY.search(content)
        if m and m.group(1) != '（待填充）':
            info['summary'] = m.group(1)

        # Start time
        m = RE_START_TIME.search(content)
        if m:
            info['start_time'] = m.group(1)

        # PID
        m = RE_PID.search(content)
        if m:
            info['pid'] = int(m.group(1))

        # End time (auto-filled section)
        m = RE_AUTO_END_TIME.search(content)
        if m:
            info['end_time'] = m.group(1)
            info['status'] = 'completed'

        # Exit code
        m = RE_AUTO_EXIT_CODE.search(content)
        if m:
            try:
                info['exit_code'] = int(m.group(1))
            except ValueError:
                info['exit_code'] = m.group(1)

        # Context section (for extracting memories)
        context_match = re.search(r'## 上下文\s*\n+(.+?)(?=\n##|\Z)', content, re.DOTALL)
        if context_match:
            info['context_summary'] = context_match.group(1).strip()
            if info['context_summary'] == '（待填充）':
                info['context_summary'] = None

        # Determine if truly complete
        if info.get('summary') and info.get('summary') != '（待填充）':
            info['status'] = 'completed'
        elif info.get('end_time'):
            info['status'] = 'completed'
        else:
            info['status'] = 'skeleton'

    except Exception as e:
        info['parse_error'] = str(e)

    return info


def parse_log_file(filepath: str) -> list:
    """Parse a .log file and extract tool call events."""
    events = []
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                m = RE_LOG_LINE.match(line)
                if m:
                    events.append({
                        'timestamp': m.group(1),
                        'tool_name': m.group(2),
                        'detail': m.group(3).strip() if m.group(3) else ''
                    })
    except Exception:
        pass
    return events


def find_session_files(sessions_dir: str) -> list:
    """Find all .md session files in sessions/ directory (including archive/)."""
    # Read index first for time resolution of descriptive filenames
    session_index = read_session_index(sessions_dir)

    files = []
    for root, dirs, filenames in os.walk(sessions_dir):
        for fn in filenames:
            m = RE_FILENAME.match(fn)
            if not m:
                continue
            date = m.group(1)
            time_raw = m.group(2)
            ext = m.group(3)

            # Extract HHMM from time_raw (may have descriptive suffix or be purely descriptive)
            time_val = time_raw[:4] if (time_raw[:4].isdigit() and len(time_raw[:4]) == 4) else None
            if time_val is None:
                # Descriptive filename: look up time from index
                for key, entry in session_index.items():
                    if entry['date'] == date:
                        time_val = entry['time']
                        break
                if time_val is None:
                    time_val = '0000'

            files.append({
                'path': os.path.join(root, fn),
                'date': date,
                'time': time_val,
                'ext': ext,
                'in_archive': 'archive' in root.split(os.sep)
            })
    # Group .md and .log
    md_files = {f['date'] + '_' + f['time']: f for f in files if f['ext'] == 'md'}
    log_files = {f['date'] + '_' + f['time']: f for f in files if f['ext'] == 'log'}

    result = []
    for key, md in md_files.items():
        entry = dict(md)
        entry['log_path'] = log_files[key]['path'] if key in log_files else None
        result.append(entry)
    return sorted(result, key=lambda x: x['date'] + x['time'])


def read_session_index(sessions_dir: str) -> dict:
    """Read .session-index JSONL file."""
    index = {}
    idx_path = os.path.join(sessions_dir, '.session-index')
    if os.path.exists(idx_path):
        with open(idx_path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    key = f"{entry['date']}_{entry['time']}"
                    index[key] = entry
                except json.JSONDecodeError:
                    pass
    return index


def migrate(project_dir: str, dry_run: bool = False):
    """Main migration function."""
    sessions_dir = os.path.join(project_dir, '.claude', 'context', 'sessions')
    if not os.path.isdir(sessions_dir):
        print(f"Error: sessions directory not found: {sessions_dir}")
        return

    db_path = get_db_path(project_dir)
    ensure_schema(project_dir)

    files = find_session_files(sessions_dir)
    session_index = read_session_index(sessions_dir)

    print(f"Found {len(files)} .md files, {len(session_index)} index entries")
    print(f"Target DB: {db_path}")
    if dry_run:
        print("DRY RUN — no changes will be made")
    print()

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    imported = 0
    skipped = 0
    events_total = 0
    memories_total = 0

    for f in files:
        key = f"{f['date']}_{f['time']}"
        slug = key

        # Check if already imported
        existing = conn.execute(
            "SELECT id FROM sessions WHERE slug=?", (slug,)
        ).fetchone()
        if existing:
            skipped += 1
            continue

        # Parse .md
        md_info = parse_md_file(f['path'])

        # Determine status
        status = 'skeleton'
        if key in session_index:
            status = session_index[key].get('status', 'skeleton')
        if md_info.get('status') == 'completed':
            status = 'completed'

        if dry_run:
            print(f"  [{status:9s}] {slug} — {md_info.get('summary', '(no summary)')[:80]}")
            imported += 1
            continue

        # Create session in DB
        session_id = new_id()
        try:
            conn.execute("""
                INSERT INTO sessions (id, date, time, slug, pid, status, summary,
                       context_summary, start_time, end_time, exit_code)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """, (
                session_id,
                f['date'],
                f['time'],
                slug,
                md_info.get('pid'),
                status,
                md_info.get('summary'),
                md_info.get('context_summary'),
                md_info.get('start_time'),
                md_info.get('end_time'),
                md_info.get('exit_code')
            ))

            # Parse .log and import events
            if f.get('log_path'):
                log_events = parse_log_file(f['log_path'])
                for evt in log_events:
                    conn.execute("""
                        INSERT INTO events (session_id, timestamp, tool_name, tool_input_summary)
                        VALUES (?,?,?,?)
                    """, (session_id, evt['timestamp'], evt['tool_name'], evt['detail'][:200]))
                events_total += len(log_events)

            # Extract initial memories from context
            if md_info.get('context_summary') and len(md_info['context_summary']) > 10:
                # Store as episodic memory for completed sessions
                if status == 'completed':
                    conn.execute("""
                        INSERT OR IGNORE INTO memories (id, type, content, source_session_id,
                               confidence, importance, fingerprint, created_at)
                        VALUES (?, 'episodic', ?, ?, 0.8, 0.3, ?, ?)
                    """, (
                        new_id(),
                        f"Session {slug}: {md_info.get('summary', 'No summary')}",
                        session_id,
                        '',  # fingerprint placeholder
                        now_iso()
                    ))
                    memories_total += 1

            imported += 1
            if imported % 10 == 0:
                print(f"  Imported {imported}/{len(files)}...")
                conn.commit()

        except Exception as e:
            print(f"  ERROR importing {slug}: {e}")

    conn.commit()

    # Summary
    print()
    print(f"Results: {imported} imported, {skipped} skipped, {events_total} events, {memories_total} memories")

    # Verify against .session-index
    db_count = conn.execute("SELECT count(*) as cnt FROM sessions").fetchone()['cnt']
    idx_count = len(session_index)
    print(f"DB sessions: {db_count}, Index entries: {idx_count}")

    if not dry_run:
        # Count by status
        for row in conn.execute(
            "SELECT status, count(*) as cnt FROM sessions GROUP BY status"
        ).fetchall():
            print(f"  {row['status']}: {row['cnt']}")

    conn.close()
    return imported


def verify(project_dir: str):
    """Verify DB counts match .session-index."""
    sessions_dir = os.path.join(project_dir, '.claude', 'context', 'sessions')
    db_path = get_db_path(project_dir)

    session_index = read_session_index(sessions_dir)
    idx_count = len(session_index)
    idx_complete = sum(1 for v in session_index.values() if v['status'] == 'complete')
    idx_skeleton = sum(1 for v in session_index.values() if v['status'] == 'skeleton')

    if not os.path.exists(db_path):
        print(f"DB not found: {db_path}")
        print(f"Index: {idx_count} entries ({idx_complete} complete, {idx_skeleton} skeleton)")
        return

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    db_count = conn.execute("SELECT count(*) as cnt FROM sessions").fetchone()['cnt']
    db_complete = conn.execute(
        "SELECT count(*) as cnt FROM sessions WHERE status='completed'"
    ).fetchone()['cnt']
    db_skeleton = conn.execute(
        "SELECT count(*) as cnt FROM sessions WHERE status='skeleton'"
    ).fetchone()['cnt']

    print(f"Verification:")
    print(f"  Sessions:    DB={db_count}  Index={idx_count}  {'OK' if db_count == idx_count else 'MISMATCH'}")
    print(f"  Complete:    DB={db_complete}  Index={idx_complete}  {'OK' if db_complete == idx_complete else 'MISMATCH'}")
    print(f"  Skeleton:    DB={db_skeleton}  Index={idx_skeleton}  {'OK' if db_skeleton == idx_skeleton else 'MISMATCH'}")

    # List missing
    db_slugs = {r['slug'] for r in conn.execute("SELECT slug FROM sessions").fetchall()}
    idx_keys = {f"{e['date']}_{e['time']}" for e in session_index.values()}
    missing_in_db = idx_keys - db_slugs
    missing_in_idx = db_slugs - idx_keys

    if missing_in_db:
        print(f"  In index but not DB: {sorted(missing_in_db)}")
    if missing_in_idx:
        print(f"  In DB but not index: {sorted(missing_in_idx)}")

    conn.close()


if __name__ == "__main__":
    project_dir = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    mode = sys.argv[2] if len(sys.argv) > 2 else "--migrate"

    if mode == "--dry-run":
        migrate(project_dir, dry_run=True)
    elif mode == "--verify":
        verify(project_dir)
    elif mode == "--migrate":
        migrate(project_dir, dry_run=False)
    else:
        print(f"Usage: python migrate.py [project_dir] [--migrate|--dry-run|--verify]")
        sys.exit(1)
