#!/usr/bin/env python3
"""
Claude Code Context Manager - MCP Server
v4.0: FastMCP decorator-driven — no manual TOOLS/handlers sync needed.
CLI mode retained for shell script integration via mcp-cli.sh.
"""

import sys
import os
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from db_core import ensure_schema
from session_ops import (
    session_create, session_finalize, session_get, session_list,
    session_check_active, session_mark_abandoned, session_events,
    session_events_by_slug, session_compile_md,
    session_stats, session_find_status,
    event_log, session_clear_suspect,
    stats_overview,
    briefing_generate, briefing_get,
)
from memory_ops import (
    memory_search, memory_store, memory_get, memory_update, memory_delete, memory_list,
    memory_relation_create, memory_relations_get, memory_graph_get,
    decision_record, decision_list,
    pattern_register, pattern_list,
    preference_get, preference_set,
)
from maintenance_ops import decay_run, dedup_run
from decision_audit import decision_log, outcome_review
from analytics import run_analytics, get_behavior_profile, get_analysis_runs, run_task_sync
from orphan_ops import session_orphan_scan
from shield import security_scan
from transcript_ops import enrich_briefing
from adversarial import opus_review_prep, opus_review_submit, opus_review_state

_PD = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
_RO = ToolAnnotations(readOnlyHint=True)
_RW = ToolAnnotations(readOnlyHint=False)
_RA = ToolAnnotations(readOnlyHint=True, title="记忆操作")

mcp = FastMCP("context-manager")

# ═══════════ Memory tools ═══════════

@mcp.tool(name="memory_search", annotations=_RO, title="搜索记忆")
async def _memory_search(query: str, mem_type: str = None, limit: int = 20) -> dict:
    """Full-text search across all memories (FTS5). Returns ranked results."""
    ensure_schema(_PD)
    return memory_search(_PD, query=query, mem_type=mem_type, limit=limit)


@mcp.tool(name="memory_store", title="存储记忆")
async def _memory_store(content: str, mem_type: str = "semantic",
                        confidence: float = 1.0, importance: float = 0.5,
                        tags: list = None, auto_dedup: bool = True) -> dict:
    """Store a memory with auto-dedup (SHA256 exact + Jaccard 0.85)."""
    ensure_schema(_PD)
    return memory_store(_PD, content=content, mem_type=mem_type,
                        confidence=confidence, importance=importance,
                        tags=tags, auto_dedup=auto_dedup)


@mcp.tool(name="memory_get", annotations=_RO, title="获取记忆")
async def _memory_get(mem_id: str) -> dict:
    """Get a specific memory by ID. Increments access_count."""
    ensure_schema(_PD)
    return memory_get(_PD, mem_id=mem_id)


@mcp.tool(name="memory_update", title="更新记忆")
async def _memory_update(mem_id: str, content: str = None,
                         confidence: float = None, importance: float = None,
                         tags: list = None) -> dict:
    """Update a memory."""
    ensure_schema(_PD)
    return memory_update(_PD, mem_id=mem_id, content=content,
                         confidence=confidence, importance=importance, tags=tags)


@mcp.tool(name="memory_delete", title="删除记忆")
async def _memory_delete(mem_id: str) -> dict:
    """Delete a memory by ID."""
    ensure_schema(_PD)
    return memory_delete(_PD, mem_id=mem_id)


@mcp.tool(name="memory_list", annotations=_RO, title="列出记忆")
async def _memory_list(mem_type: str = None, limit: int = 50) -> dict:
    """List memories, optionally filtered by type."""
    ensure_schema(_PD)
    return memory_list(_PD, mem_type=mem_type, limit=limit)


@mcp.tool(name="memory_relation_create", title="创建记忆关系")
async def _memory_relation_create(source_id: str, target_id: str,
                                  relation_type: str = "relates_to",
                                  weight: float = 1.0) -> dict:
    """Create a typed relation between two memories (relates_to/depends_on/contradicts/extends/implements/derived_from)."""
    ensure_schema(_PD)
    return memory_relation_create(_PD, source_id=source_id, target_id=target_id,
                                  relation_type=relation_type, weight=weight)


@mcp.tool(name="memory_relations_get", annotations=_RO, title="获取记忆关系")
async def _memory_relations_get(mem_id: str, direction: str = "both",
                                max_depth: int = 2) -> dict:
    """Get related memories via BFS graph traversal."""
    ensure_schema(_PD)
    return memory_relations_get(_PD, mem_id=mem_id, direction=direction, max_depth=max_depth)


@mcp.tool(name="memory_graph_get", annotations=_RO, title="获取记忆图谱")
async def _memory_graph_get(mem_id: str, max_depth: int = 3) -> dict:
    """Get the full graph around a memory (nodes + edges)."""
    ensure_schema(_PD)
    return memory_graph_get(_PD, mem_id=mem_id, max_depth=max_depth)


# ═══════════ Session tools ═══════════

@mcp.tool(name="session_list", annotations=_RO, title="列出会话")
async def _session_list(status: str = None, limit: int = 20, offset: int = 0) -> dict:
    """List sessions with optional status filter. Use to find recent sessions."""
    ensure_schema(_PD)
    return session_list(_PD, status=status, limit=limit, offset=offset)


@mcp.tool(name="session_get", annotations=_RO, title="获取会话详情")
async def _session_get(session_id: str = None, slug: str = None) -> dict:
    """Get session details by ID or slug — status, events count, timestamps."""
    ensure_schema(_PD)
    return session_get(_PD, session_id=session_id, slug=slug)


@mcp.tool(name="session_events", annotations=_RO, title="查看会话事件")
async def _session_events(session_id: str = None, limit: int = 200) -> dict:
    """Get all tool call events for a session — what happened in that session."""
    ensure_schema(_PD)
    return session_events(_PD, session_id=session_id, limit=limit)


# ═══════════ Decision tools ═══════════

@mcp.tool(name="decision_record", title="记录决策")
async def _decision_record(title: str, context: str = None,
                           rationale: str = None, alternatives: list = None) -> dict:
    """Record an architectural decision (ADR-style)."""
    ensure_schema(_PD)
    return decision_record(_PD, title=title, context=context,
                           rationale=rationale, alternatives=alternatives)


@mcp.tool(name="decision_list", annotations=_RO, title="列出决策")
async def _decision_list(status: str = "active", limit: int = 20) -> dict:
    """List active decisions (ADR-style)."""
    ensure_schema(_PD)
    return decision_list(_PD, status=status, limit=limit)


# ═══════════ Pattern tools ═══════════

@mcp.tool(name="pattern_register", title="注册模式")
async def _pattern_register(title: str, description: str = None,
                            category: str = "convention", confidence: float = 0.5) -> dict:
    """Register a recurring pattern or insight."""
    ensure_schema(_PD)
    return pattern_register(_PD, title=title, description=description,
                            category=category, confidence=confidence)


@mcp.tool(name="pattern_list", annotations=_RO, title="列出模式")
async def _pattern_list(category: str = None, limit: int = 20) -> dict:
    """List patterns by category."""
    ensure_schema(_PD)
    return pattern_list(_PD, category=category, limit=limit)


# ═══════════ Preference tools ═══════════

@mcp.tool(name="preference_get", annotations=_RO, title="获取偏好")
async def _preference_get(key: str) -> dict:
    """Get a preference value by key."""
    ensure_schema(_PD)
    return preference_get(_PD, key=key)


@mcp.tool(name="preference_set", title="设置偏好")
async def _preference_set(key: str, value: str, category: str = None) -> dict:
    """Set a preference key-value pair."""
    ensure_schema(_PD)
    return preference_set(_PD, key=key, value=value, category=category)


# ═══════════ Stats / Briefing tools ═══════════

@mcp.tool(name="stats_overview", annotations=_RO, title="统计概览")
async def _stats_overview() -> dict:
    """Get auto-computed statistics. Replaces manual STATUS.md."""
    ensure_schema(_PD)
    return stats_overview(_PD)


@mcp.tool(name="briefing_generate", annotations=_RO, title="生成简报")
async def _briefing_generate(max_tokens: int = 500) -> dict:
    """Generate session briefing from DB (<=500 tokens)."""
    ensure_schema(_PD)
    return briefing_generate(_PD, max_tokens=max_tokens)


@mcp.tool(name="briefing_get", annotations=_RO, title="获取简报")
async def _briefing_get() -> dict:
    """Get the current cached briefing."""
    ensure_schema(_PD)
    return briefing_get(_PD)


# ═══════════ Maintenance tools ═══════════

@mcp.tool(name="dedup_run", title="运行去重")
async def _dedup_run(dry_run: bool = False) -> dict:
    """Run batch dedup. Use dry_run=true to preview."""
    ensure_schema(_PD)
    return dedup_run(_PD, dry_run=dry_run)


@mcp.tool(name="decay_run", title="运行衰减")
async def _decay_run() -> dict:
    """Run type-aware decay on memories. ax3: weighted by access_count+confidence."""
    ensure_schema(_PD)
    return decay_run(_PD)


# ═══════════ Analytics / Review tools ═══════════

@mcp.tool(name="get_behavior_profile", annotations=_RO, title="获取行为画像")
async def _get_behavior_profile(dimension: str = None) -> dict:
    """Query quantitative behavior profile. Dimension filter optional."""
    ensure_schema(_PD)
    return get_behavior_profile(_PD, dimension=dimension)


@mcp.tool(name="get_analysis_runs", annotations=_RO, title="查看分析历史")
async def _get_analysis_runs(limit: int = 10) -> dict:
    """Query analysis run history."""
    ensure_schema(_PD)
    return get_analysis_runs(_PD, limit=limit)


@mcp.tool(name="outcome_review", title="结果评审")
async def _outcome_review(decision_type: str = None, min_age_days: int = None) -> dict:
    """ax5: Review past automatic decisions for accuracy. Closes the feedback loop."""
    ensure_schema(_PD)
    return outcome_review(_PD, decision_type=decision_type, min_age_days=min_age_days)


@mcp.tool(name="run_task_sync", title="任务同步")
async def _run_task_sync() -> dict:
    """v4.5: Sync events to task_states table and refresh .planning/ JSON cache."""
    ensure_schema(_PD)
    return run_task_sync(_PD)


# ═══════════ Orphan recovery (v5.0) ═══════════

@mcp.tool(name="session_orphan_scan", annotations=_RO, title="扫描遗孤会话")
async def _session_orphan_scan(auto_abandon: bool = False) -> dict:
    """Scan active sessions for orphans using 3D scoring (time + pid + checkpoint).
    ax10: two-phase abandon — first sets suspect_at, second confirms."""
    ensure_schema(_PD)
    return session_orphan_scan(_PD, auto_abandon=auto_abandon)


# ═══════════ Security scan (v3.2.0 stub) ═══════════

@mcp.tool(name="security_scan", annotations=_RO, title="安全扫描")
async def _security_scan(categories: list = None) -> dict:
    """AgentShield v1.0.0 — 47 rules across 5 categories: secrets(14) + permissions(10) + hooks(11) + mcp(6) + agents(6)."""
    ensure_schema(_PD)
    return security_scan(_PD, categories=categories)


# ═══════════ Opus adversarial review tools ═══════════

@mcp.tool(name="opus_review_prep", annotations=_RO, title="审查准备")
async def _opus_review_prep(base_ref: str = "HEAD~1") -> dict:
    """Prepare adversarial review context from git diff. Returns review prompt + changed files."""
    ensure_schema(_PD)
    return opus_review_prep(_PD, base_ref=base_ref)


@mcp.tool(name="opus_review_submit", annotations=_RW, title="审查提交")
async def _opus_review_submit(findings: list = None, session_id: str = None) -> dict:
    """Submit adversarial review findings. Stores to decision_audit for outcome_review (ax5)."""
    ensure_schema(_PD)
    return opus_review_submit(_PD, findings=findings, session_id=session_id)


@mcp.tool(name="opus_review_state", annotations=_RO, title="审查状态")
async def _opus_review_state() -> dict:
    """Get current review pipeline state."""
    ensure_schema(_PD)
    return opus_review_state(_PD)


# ═══════════ CLI path (unchanged — bash hooks) ═══════════

def cli_main():
    """Command-line interface for Bash hooks via mcp-cli.sh."""
    if len(sys.argv) < 3:
        print(json.dumps({"error": "Usage: python server.py <project_dir> <command> [args_json]"}))
        sys.exit(1)

    project_dir = sys.argv[1]
    command = sys.argv[2]
    args = {}
    if len(sys.argv) > 3:
        try:
            args = json.loads(sys.argv[3])
        except json.JSONDecodeError:
            args = {}

    ensure_schema(project_dir)

    handlers = {
        "session_create": session_create,
        "session_finalize": session_finalize,
        "session_get": session_get,
        "memory_relation_create": memory_relation_create,
        "memory_relations_get": memory_relations_get,
        "memory_graph_get": memory_graph_get,
        "session_list": session_list,
        "session_check_active": session_check_active,
        "session_mark_abandoned": session_mark_abandoned,
        "session_events": session_events,
        "session_events_by_slug": session_events_by_slug,
        "session_compile_md": session_compile_md,
        "session_stats": session_stats,
        "session_find_status": session_find_status,
        "event_log": event_log,
        "memory_search": memory_search,
        "memory_store": memory_store,
        "memory_get": memory_get,
        "memory_update": memory_update,
        "memory_delete": memory_delete,
        "memory_list": memory_list,
        "decision_record": decision_record,
        "decision_list": decision_list,
        "pattern_register": pattern_register,
        "pattern_list": pattern_list,
        "preference_get": preference_get,
        "preference_set": preference_set,
        "stats_overview": stats_overview,
        "briefing_generate": briefing_generate,
        "briefing_get": briefing_get,
        "decay_run": decay_run,
        "dedup_run": dedup_run,
        "outcome_review": outcome_review,
        "ensure_schema": ensure_schema,
        "run_analytics": run_analytics,
        "get_behavior_profile": get_behavior_profile,
        "get_analysis_runs": get_analysis_runs,
        "run_task_sync": run_task_sync,
        "session_orphan_scan": session_orphan_scan,
        "security_scan": security_scan,
        "session_clear_suspect": session_clear_suspect,
        "enrich_briefing": enrich_briefing,
        "opus_review_prep": opus_review_prep,
        "opus_review_submit": opus_review_submit,
        "opus_review_state": opus_review_state,
    }

    try:
        handler = handlers.get(command)
        if not handler:
            result = {"error": f"Unknown command: {command}"}
        elif command == "session_check_active":
            result = handler(project_dir)
        elif command in ("stats_overview", "briefing_get", "decay_run",
                         "ensure_schema", "run_analytics", "run_task_sync",
                         "session_clear_suspect"):
            result = handler(project_dir)
        else:
            result = handler(project_dir, **args)
    except Exception as e:
        result = {"error": str(e)}

    print(json.dumps(result, ensure_ascii=False, default=str))


# ═══════════ Entry point ═══════════

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--mcp":
        mcp.run()
    else:
        cli_main()
