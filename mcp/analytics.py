#!/usr/bin/env python3
"""
v4.0: Quantitative Analytics + Profile Aggregator
Pure SQL aggregation, zero token cost, no LLM dependency.

Triggered by analysis-scheduler.sh via mcp-cli.sh:
  mcp-cli.sh <project_dir> run_analytics '{}'

Outputs:
  - behavior_profile table (dimension-key-value)
  - analysis_runs table (audit trail)
  - user.md auto-segment (appended to existing file)
"""

import json
import time
import os
from datetime import datetime, timezone, timedelta
from typing import Optional, Any
from collections import Counter

from db_core import get_db, get_db_path, ensure_schema, now_iso


def run_analytics(project_dir: Optional[str] = None,
                  _trigger: str = "scheduler") -> dict:
    """
    Main entry point. Runs all quantitative analyzers.
    Returns summary dict for the scheduler.
    """
    ensure_schema(project_dir)
    start_ts = int(time.time() * 1000)
    results = {"dimensions_updated": 0, "details": [], "error": None}

    try:
        with get_db(project_dir) as conn:
            # Count scope
            session_count = conn.execute(
                "SELECT COUNT(*) FROM sessions"
            ).fetchone()[0]
            event_count = conn.execute(
                "SELECT COUNT(*) FROM events"
            ).fetchone()[0]

            if event_count < 10:
                return {"error": "Not enough events for analysis", "event_count": event_count}

            # ── Dimension 1: Tool frequency ──
            dims = _analyze_tool_frequency(conn)
            results["details"].extend(dims)

            # ── Dimension 2: Edit/Write ratio ──
            dims = _analyze_edit_style(conn)
            results["details"].extend(dims)

            # ── Dimension 3: Search habits ──
            dims = _analyze_search_habits(conn)
            results["details"].extend(dims)

            # ── Dimension 4: Hot files ──
            dims = _analyze_hot_files(conn)
            results["details"].extend(dims)

            # ── Dimension 5: Error rate (v4.0: new data source) ──
            dims = _analyze_error_rate(conn)
            results["details"].extend(dims)

            # ── Dimension 6: Session pace ──
            dims = _analyze_session_pace(conn)
            results["details"].extend(dims)

            # ── Dimension 7: Task states (v4.5 L1.5 persistence) ──
            dims = _analyze_task_states(conn, project_dir)
            results["details"].extend(dims)

            results["dimensions_updated"] = len(results["details"])

            # Record analysis run
            end_ts = int(time.time() * 1000)
            conn.execute("""
                INSERT INTO analysis_runs
                (triggered_by, sessions_analyzed, events_analyzed, results_summary, duration_ms)
                VALUES (?, ?, ?, ?, ?)
            """, (_trigger, session_count, event_count,
                  json.dumps(results["details"], ensure_ascii=False),
                  end_ts - start_ts))

        # ── Update user.md auto-segment ──
        _update_user_md(project_dir)

    except Exception as e:
        results["error"] = str(e)

    return results


def _analyze_tool_frequency(conn) -> list:
    """Dimension: tool usage distribution."""
    rows = conn.execute("""
        SELECT tool_name, COUNT(*) as cnt
        FROM events
        WHERE tool_name IS NOT NULL AND tool_name != ''
        GROUP BY tool_name
        ORDER BY cnt DESC
    """).fetchall()

    total = sum(r['cnt'] for r in rows)
    if total == 0:
        return []

    updated = []
    # Clear old tool_frequency entries
    conn.execute(
        "DELETE FROM behavior_profile WHERE dimension='tool_frequency'"
    )

    for r in rows[:8]:  # Top 8 tools
        ratio = round(r['cnt'] / total, 3)
        conn.execute("""
            INSERT OR REPLACE INTO behavior_profile (dimension, key, value, confidence, source, updated_at)
            VALUES ('tool_frequency', ?, ?, 1.0, 'quantitative', ?)
        """, (r['tool_name'], str(ratio), now_iso()))
        updated.append(f"tool_frequency:{r['tool_name']}={ratio}")

    return updated


def _analyze_edit_style(conn) -> list:
    """Dimension: Edit vs Write ratio."""
    edit_cnt = conn.execute(
        "SELECT COUNT(*) FROM events WHERE tool_name='Edit'"
    ).fetchone()[0]
    write_cnt = conn.execute(
        "SELECT COUNT(*) FROM events WHERE tool_name='Write'"
    ).fetchone()[0]

    updated = []
    conn.execute(
        "DELETE FROM behavior_profile WHERE dimension='edit_style'"
    )

    if write_cnt > 0:
        ratio = round(edit_cnt / write_cnt, 1)
    elif edit_cnt > 0:
        ratio = float(edit_cnt)  # All edit, no write
    else:
        return updated

    conn.execute("""
        INSERT OR REPLACE INTO behavior_profile (dimension, key, value, confidence, source, updated_at)
        VALUES ('edit_style', 'edit_over_write', ?, 0.9, 'quantitative', ?)
    """, (str(ratio), now_iso()))
    updated.append(f"edit_style:edit_over_write={ratio}")
    return updated


def _analyze_search_habits(conn) -> list:
    """Dimension: search tool preference (Grep vs Glob vs WebSearch)."""
    search_tools = ['Grep', 'Glob', 'WebSearch', 'WebFetch']
    total_search = conn.execute(
        "SELECT COUNT(*) FROM events WHERE tool_name IN ({})".format(
            ','.join(f"'{t}'" for t in search_tools)
        )
    ).fetchone()[0]

    if total_search == 0:
        return []

    updated = []
    conn.execute(
        "DELETE FROM behavior_profile WHERE dimension='search_habit'"
    )

    for tool in search_tools:
        cnt = conn.execute(
            "SELECT COUNT(*) FROM events WHERE tool_name=?", (tool,)
        ).fetchone()[0]
        if cnt > 0:
            ratio = round(cnt / total_search, 2)
            conn.execute("""
                INSERT OR REPLACE INTO behavior_profile (dimension, key, value, confidence, source, updated_at)
                VALUES ('search_habit', ?, ?, 0.95, 'quantitative', ?)
            """, (tool.lower(), str(ratio), now_iso()))
            updated.append(f"search_habit:{tool.lower()}={ratio}")

    return updated


def _analyze_hot_files(conn) -> list:
    """Dimension: most frequently accessed file paths."""
    rows = conn.execute("""
        SELECT file_path, COUNT(*) as cnt
        FROM events
        WHERE file_path IS NOT NULL AND file_path != ''
        GROUP BY file_path
        ORDER BY cnt DESC
        LIMIT 10
    """).fetchall()

    if not rows:
        return []

    updated = []
    conn.execute(
        "DELETE FROM behavior_profile WHERE dimension='hot_files'"
    )

    for r in rows:
        conn.execute("""
            INSERT OR REPLACE INTO behavior_profile (dimension, key, value, confidence, source, updated_at)
            VALUES ('hot_files', ?, ?, 0.85, 'quantitative', ?)
        """, (r['file_path'], str(r['cnt']), now_iso()))
        updated.append(f"hot_files:{r['file_path']}={r['cnt']}")

    return updated


def _analyze_error_rate(conn) -> list:
    """Dimension: error rate by tool (v4.0: uses exit_code column)."""
    rows = conn.execute("""
        SELECT tool_name,
               COUNT(*) as total,
               SUM(CASE WHEN exit_code IS NOT NULL AND exit_code != 0 THEN 1 ELSE 0 END) as errors
        FROM events
        WHERE exit_code IS NOT NULL
        GROUP BY tool_name
        HAVING errors > 0
        ORDER BY errors DESC
        LIMIT 5
    """).fetchall()

    if not rows:
        return []

    updated = []
    conn.execute(
        "DELETE FROM behavior_profile WHERE dimension='error_rate'"
    )

    for r in rows:
        rate = round(r['errors'] / r['total'], 2)
        conn.execute("""
            INSERT OR REPLACE INTO behavior_profile (dimension, key, value, confidence, source, updated_at)
            VALUES ('error_rate', ?, ?, 0.9, 'quantitative', ?)
        """, (r['tool_name'], str(rate), now_iso()))
        updated.append(f"error_rate:{r['tool_name']}={rate}")

    return updated


def _analyze_session_pace(conn) -> list:
    """Dimension: session duration and event density."""
    rows = conn.execute("""
        SELECT slug, duration_min,
               (SELECT COUNT(*) FROM events WHERE events.session_id = sessions.id) as event_count
        FROM sessions
        WHERE duration_min IS NOT NULL AND duration_min > 0
        ORDER BY created_at DESC
        LIMIT 20
    """).fetchall()

    if not rows:
        return []

    avg_duration = sum(r['duration_min'] for r in rows) / len(rows)
    avg_events = sum(r['event_count'] for r in rows) / len(rows)
    density = round(avg_events / max(avg_duration, 1), 1)

    updated = []
    conn.execute(
        "DELETE FROM behavior_profile WHERE dimension='session_pace'"
    )

    conn.execute("""
        INSERT OR REPLACE INTO behavior_profile (dimension, key, value, confidence, source, updated_at)
        VALUES ('session_pace', 'avg_duration_min', ?, 0.9, 'quantitative', ?)
    """, (str(round(avg_duration, 1)), now_iso()))
    updated.append(f"session_pace:avg_duration_min={round(avg_duration,1)}")

    conn.execute("""
        INSERT OR REPLACE INTO behavior_profile (dimension, key, value, confidence, source, updated_at)
        VALUES ('session_pace', 'events_per_min', ?, 0.9, 'quantitative', ?)
    """, (str(density), now_iso()))
    updated.append(f"session_pace:events_per_min={density}")

    return updated


def _analyze_task_states(conn, project_dir: str) -> list:
    """Dimension 7 (v4.5): derive task states from events, sync to SQLite + JSON cache."""
    import os as _os
    import hashlib

    rows = conn.execute("""
        SELECT e.id, e.tool_name, e.tool_input_summary, e.session_id, e.timestamp
        FROM events e
        WHERE e.tool_name IN ('TaskCreate', 'TaskUpdate')
        ORDER BY e.id ASC
    """).fetchall()

    if not rows:
        return []

    # Phase 1: parse events, build latest-state dict
    tasks = {}
    for r in rows:
        raw_summary = r['tool_input_summary'] or ''
        ti = None

        # Try JSON parse (v4.5 format: full tool_input as JSON)
        if raw_summary and raw_summary[0] == '{':
            try:
                ti = json.loads(raw_summary)
            except (json.JSONDecodeError, TypeError):
                ti = None

        # Fallback: non-JSON summary from legacy events
        if ti is None or not isinstance(ti, dict):
            # Legacy TaskCreate: summary is the subject string
            # Legacy TaskUpdate: summary is just the taskId number
            if r['tool_name'] == 'TaskUpdate' and raw_summary.isdigit():
                ti = {'taskId': raw_summary, 'status': 'completed'}
            else:
                ti = {'subject': raw_summary or 'Untitled'}

        task_id = ti.get('taskId', '')
        if not task_id:
            subj = ti.get('subject', 'Untitled')
            task_id = hashlib.sha256(
                (subj + (r['session_id'] or '')).encode()
            ).hexdigest()[:12]

        tasks[task_id] = {
            'task_id': task_id,
            'subject': ti.get('subject', 'Untitled'),
            'description': ti.get('description', ''),
            'status': ti.get('status', 'pending'),
            'source_session_id': r['session_id'],
            'plan_slug': 'default',  # resolved in Phase 2
        }

    # Phase 2: resolve plan_slug from .planning/index.json
    plan_slug = 'default'
    if project_dir:
        idx_path = _os.path.join(project_dir, '.planning', 'index.json')
        if _os.path.exists(idx_path):
            try:
                with open(idx_path, encoding='utf-8') as f:
                    idx = json.load(f)
                active = idx.get('active', '')
                if active and idx.get('plans', {}).get(active, {}).get('status') in ('active', 'paused'):
                    plan_slug = active
            except Exception:
                pass

    # Phase 3: write to SQLite task_states (canonical)
    updated = []
    for task_id, t in tasks.items():
        t['plan_slug'] = plan_slug
        conn.execute("""
            INSERT OR REPLACE INTO task_states
            (task_id, plan_slug, subject, description, status, updated_at, source_session_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (task_id, plan_slug, t['subject'], t['description'],
              t['status'], now_iso(), t['source_session_id']))
        updated.append(f"task_state:{task_id}={t['status']}")

    # Phase 4: refresh JSON cache from SQLite
    if project_dir:
        all_tasks = conn.execute("""
            SELECT * FROM task_states WHERE plan_slug = ? ORDER BY updated_at DESC
        """, (plan_slug,)).fetchall()

        plan_dir = _os.path.join(project_dir, '.planning')
        slug_dir = _os.path.join(plan_dir, plan_slug)
        _os.makedirs(slug_dir, exist_ok=True)

        state = {
            'slug': plan_slug,
            'status': 'active',
            'tasks': [{
                'id': r['task_id'],
                'subject': r['subject'],
                'description': r['description'] or '',
                'status': r['status'],
                'created_at': r['created_at'],
                'updated_at': r['updated_at'],
                'completed_at': r['completed_at'],
            } for r in all_tasks],
            'updated_at': now_iso(),
            '_source': 'analytics_sync'
        }

        state_path = _os.path.join(slug_dir, 'state.json')
        tmp = state_path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
        _os.replace(tmp, state_path)

        # Also write index.json
        idx_path = _os.path.join(plan_dir, 'index.json')
        idx = {'active': '', 'plans': {}}
        if _os.path.exists(idx_path):
            try:
                with open(idx_path, encoding='utf-8') as f:
                    idx = json.load(f)
            except Exception:
                pass
        idx['active'] = plan_slug
        idx.setdefault('plans', {})[plan_slug] = {
            'status': 'active',
            'created_at': state['tasks'][0]['created_at'] if state['tasks'] else now_iso(),
            'task_count': len(all_tasks),
            'updated_at': now_iso()
        }
        tmp_idx = idx_path + '.tmp'
        with open(tmp_idx, 'w', encoding='utf-8') as f:
            json.dump(idx, f, ensure_ascii=False, indent=2)
        _os.replace(tmp_idx, idx_path)

    return updated


def _update_user_md(project_dir: str) -> dict:
    """
    Read behavior_profile and generate/update the auto-segment
    in user.md. Only writes the <!-- auto --> block — never
    touches the user's hand-written declarations.

    Uses the GLOBAL user.md (~/.claude/profile/user.md),
    not the project-level CLAUDE.md.
    """
    user_md_path = os.path.expanduser("~/.claude/profile/user.md")
    os.makedirs(os.path.dirname(user_md_path), exist_ok=True)

    # Read existing or create skeleton
    if os.path.exists(user_md_path):
        with open(user_md_path, 'r', encoding='utf-8') as f:
            content = f.read()
    else:
        content = _default_user_md()

    # Query behavior_profile
    with get_db(project_dir) as conn:
        rows = conn.execute("""
            SELECT dimension, key, value, confidence
            FROM behavior_profile
            ORDER BY dimension, key
        """).fetchall()

    profile = {}
    for r in rows:
        profile.setdefault(r['dimension'], []).append({
            'key': r['key'], 'value': r['value'], 'confidence': r['confidence']
        })

    # Build auto-segment
    auto_lines = ["\n## 技能领域（系统自动更新）", ""]
    auto_lines.append(f"> 最后更新: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    auto_lines.append("")

    if 'tool_frequency' in profile:
        top_tools = sorted(profile['tool_frequency'],
                          key=lambda x: float(x['value']), reverse=True)[:5]
        tools_str = "、".join(
            f"{t['key']}({int(float(t['value'])*100)}%)" for t in top_tools
        )
        auto_lines.append(f"- **常用工具**: {tools_str}")

    if 'edit_style' in profile:
        ratio = float(profile['edit_style'][0]['value'])
        if ratio >= 3:
            style = "偏好增量修改（Edit 远多于 Write）"
        elif ratio >= 1:
            style = "均衡使用 Edit 和 Write"
        else:
            style = "偏好全量重写（Write 多于 Edit）"
        auto_lines.append(f"- **编辑风格**: {style} (Edit:Write = {ratio}:1)")

    if 'search_habit' in profile:
        habits = {h['key']: float(h['value']) for h in profile['search_habit']}
        primary = max(habits, key=habits.get) if habits else None
        if primary:
            auto_lines.append(f"- **搜索偏好**: 优先使用 {primary}")

    if 'error_rate' in profile:
        errors = sorted(profile['error_rate'],
                       key=lambda x: float(x['value']), reverse=True)[:3]
        err_str = "、".join(
            f"{e['key']}({int(float(e['value'])*100)}%错误率)" for e in errors
        )
        auto_lines.append(f"- **高错误率工具**: {err_str}")

    if 'session_pace' in profile:
        pace = {p['key']: float(p['value']) for p in profile['session_pace']}
        if 'avg_duration_min' in pace:
            auto_lines.append(f"- **会话节奏**: 平均 {pace['avg_duration_min']} 分钟/会话")

    # Merge into user.md: replace existing <!-- auto --> block or append
    auto_block = "\n".join(auto_lines)

    import re
    auto_pattern = r'<!-- auto -->.*?(?:\n<!-- \/auto -->|$)'
    if re.search(auto_pattern, content, re.DOTALL):
        content = re.sub(auto_pattern, f'<!-- auto -->\n{auto_block}\n<!-- /auto -->', content, flags=re.DOTALL)
    else:
        content = content.rstrip() + f'\n\n<!-- auto -->\n{auto_block}\n<!-- /auto -->\n'

    with open(user_md_path, 'w', encoding='utf-8') as f:
        f.write(content)

    return {"updated": True, "path": user_md_path}


def _default_user_md() -> str:
    return """# 用户画像

> 使用过程中逐步完善，每次对话后如有新发现可补充。

## 角色

（待补充：当前角色、负责领域）

## 技能领域

（待补充：擅长的技术栈、工具、经验年限）

## 工作偏好

- 沟通语言：简体中文
- 架构风格：分层、极简、指针式
- 信息消费：按需加载，只读当前任务相关的模块文档
- 代码原则：单源、可测、渐进增强、扩展不改核心

## 工具链

- 笔记：Obsidian
- 开发环境：Windows + bash
- 备份：自建 claude-backup 系统

## 常用项目

- Obsidian 插件开发（读书流）
- Claude Code 上下文管理（本项目）
"""


def get_behavior_profile(project_dir: Optional[str] = None,
                          dimension: Optional[str] = None) -> dict:
    """MCP tool: query behavior profile."""
    with get_db(project_dir) as conn:
        if dimension:
            rows = conn.execute(
                "SELECT * FROM behavior_profile WHERE dimension=? ORDER BY key",
                (dimension,)
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM behavior_profile ORDER BY dimension, key"
            ).fetchall()
        return {
            "profile": [dict(r) for r in rows],
            "updated_at": now_iso()
        }


def get_analysis_runs(project_dir: Optional[str] = None,
                       limit: int = 10) -> dict:
    """MCP tool: query analysis run history."""
    with get_db(project_dir) as conn:
        rows = conn.execute(
            "SELECT * FROM analysis_runs ORDER BY created_at DESC LIMIT ?",
            (limit,)
        ).fetchall()
        return {"runs": [dict(r) for r in rows]}


def run_task_sync(project_dir: Optional[str] = None) -> dict:
    """v4.5: sync events → task_states + refresh .planning/ JSON cache."""
    with get_db(project_dir) as conn:
        dims = _analyze_task_states(conn, project_dir)
    return {"status": "ok", "details": dims, "count": len(dims)}
