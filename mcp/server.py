#!/usr/bin/env python3
"""
Claude Code Context Manager - MCP Server
Exposes all CRUD operations as MCP tools.
Also supports CLI mode for shell script integration via mcp-cli.sh.
"""

import sys
import os
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from db_core import ensure_schema, get_db_path
from session_ops import (
    session_create, session_finalize, session_get, session_list,
    session_check_active, session_mark_abandoned, session_events,
    session_events_by_slug, session_compile_md,
    session_stats, session_find_status,
    event_log,
    memory_relation_create, memory_relations_get, memory_graph_get,
    stats_overview,
    briefing_generate, briefing_get,
    decay_run, dedup_run,
)
from memory_ops import (
    memory_search, memory_store, memory_get, memory_update, memory_delete, memory_list,
    memory_hybrid_search, memory_reindex_vectors,
    decision_record, decision_list,
    pattern_register, pattern_list,
    preference_get, preference_set,
)
from analytics import run_analytics, get_behavior_profile, get_analysis_runs, run_task_sync

TOOLS = {
    "memory_search": {
        "description": "Full-text search across all memories (FTS5). Returns ranked results.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query"},
                "mem_type": {"type": "string"},
                "limit": {"type": "integer", "default": 20}
            },
            "required": ["query"]
        }
    },
    "memory_store": {
        "description": "Store a memory with auto-dedup (SHA256 exact + Jaccard 0.85).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "content": {"type": "string"},
                "mem_type": {"type": "string", "default": "semantic"},
                "confidence": {"type": "number", "default": 1.0},
                "importance": {"type": "number", "default": 0.5},
                "tags": {"type": "array", "items": {"type": "string"}},
                "auto_dedup": {"type": "boolean", "default": True}
            },
            "required": ["content"]
        }
    },
    "memory_get": {
        "description": "Get a specific memory by ID. Increments access_count.",
        "inputSchema": {
            "type": "object",
            "properties": {"mem_id": {"type": "string"}},
            "required": ["mem_id"]
        }
    },
    "memory_update": {
        "description": "Update a memory.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mem_id": {"type": "string"},
                "content": {"type": "string"},
                "confidence": {"type": "number"},
                "importance": {"type": "number"},
                "tags": {"type": "array", "items": {"type": "string"}}
            },
            "required": ["mem_id"]
        }
    },
    "memory_delete": {
        "description": "Delete a memory by ID.",
        "inputSchema": {
            "type": "object",
            "properties": {"mem_id": {"type": "string"}},
            "required": ["mem_id"]
        }
    },
    "memory_list": {
        "description": "List memories, optionally filtered by type.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mem_type": {"type": "string"},
                "limit": {"type": "integer", "default": 50}
            }
        }
    },
    "memory_relation_create": {
        "description": "Create a typed relation between two memories (relates_to/depends_on/contradicts/extends/implements/derived_from).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "source_id": {"type": "string"},
                "target_id": {"type": "string"},
                "relation_type": {"type": "string", "default": "relates_to"},
                "weight": {"type": "number", "default": 1.0}
            },
            "required": ["source_id", "target_id"]
        }
    },
    "memory_relations_get": {
        "description": "Get related memories via BFS graph traversal.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mem_id": {"type": "string"},
                "direction": {"type": "string", "default": "both"},
                "max_depth": {"type": "integer", "default": 2}
            },
            "required": ["mem_id"]
        }
    },
    "memory_graph_get": {
        "description": "Get the full graph around a memory (nodes + edges).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mem_id": {"type": "string"},
                "max_depth": {"type": "integer", "default": 3}
            },
            "required": ["mem_id"]
        }
    },
    "session_list": {
        "description": "List sessions with optional status filter.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "status": {"type": "string"},
                "limit": {"type": "integer", "default": 20},
                "offset": {"type": "integer", "default": 0}
            }
        }
    },
    "session_get": {
        "description": "Get session details by ID or slug.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "session_id": {"type": "string"},
                "slug": {"type": "string"}
            }
        }
    },
    "session_events": {
        "description": "Get all tool call events for a session.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "session_id": {"type": "string"},
                "limit": {"type": "integer", "default": 200}
            }
        }
    },
    "decision_record": {
        "description": "Record an architectural decision (ADR-style).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "context": {"type": "string"},
                "rationale": {"type": "string"},
                "alternatives": {"type": "array", "items": {"type": "string"}}
            },
            "required": ["title"]
        }
    },
    "decision_list": {
        "description": "List active decisions.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "status": {"type": "string", "default": "active"},
                "limit": {"type": "integer", "default": 20}
            }
        }
    },
    "pattern_register": {
        "description": "Register a recurring pattern or insight.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "description": {"type": "string"},
                "category": {"type": "string", "default": "convention"},
                "confidence": {"type": "number", "default": 0.5}
            },
            "required": ["title"]
        }
    },
    "pattern_list": {
        "description": "List patterns by category.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "category": {"type": "string"},
                "limit": {"type": "integer", "default": 20}
            }
        }
    },
    "preference_get": {
        "description": "Get a preference value by key.",
        "inputSchema": {
            "type": "object",
            "properties": {"key": {"type": "string"}},
            "required": ["key"]
        }
    },
    "preference_set": {
        "description": "Set a preference key-value pair.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "key": {"type": "string"},
                "value": {"type": "string"},
                "category": {"type": "string"}
            },
            "required": ["key", "value"]
        }
    },
    "stats_overview": {
        "description": "Get auto-computed statistics. Replaces manual STATUS.md.",
        "inputSchema": {"type": "object", "properties": {}}
    },
    "briefing_generate": {
        "description": "Generate session briefing from DB (<=500 tokens).",
        "inputSchema": {
            "type": "object",
            "properties": {"max_tokens": {"type": "integer", "default": 500}}
        }
    },
    "briefing_get": {
        "description": "Get the current cached briefing.",
        "inputSchema": {"type": "object", "properties": {}}
    },
    "dedup_run": {
        "description": "Run batch dedup. Use dry_run=true to preview.",
        "inputSchema": {
            "type": "object",
            "properties": {"dry_run": {"type": "boolean", "default": False}}
        }
    },
    "decay_run": {
        "description": "Run type-aware decay on memories.",
        "inputSchema": {"type": "object", "properties": {}}
    },
    "get_behavior_profile": {
        "description": "Query quantitative behavior profile. Dimension filter optional.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "dimension": {"type": "string", "description": "Filter by dimension key"}
            }
        }
    },
    "get_analysis_runs": {
        "description": "Query analysis run history.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "default": 10}
            }
        }
    },
    "run_task_sync": {
        "description": "v4.5: Sync events to task_states table and refresh .planning/ JSON cache.",
        "inputSchema": {"type": "object", "properties": {}}
    }
}


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
        "ensure_schema": ensure_schema,
        "run_analytics": run_analytics,
        "get_behavior_profile": get_behavior_profile,
        "get_analysis_runs": get_analysis_runs,
        "run_task_sync": run_task_sync,
    }

    try:
        handler = handlers.get(command)
        if not handler:
            result = {"error": f"Unknown command: {command}"}
        elif command == "session_check_active":
            result = handler(project_dir)
        elif command in ("stats_overview", "briefing_get", "decay_run",
                         "ensure_schema", "run_analytics", "run_task_sync"):
            result = handler(project_dir)
        else:
            result = handler(project_dir, **args)
    except Exception as e:
        result = {"error": str(e)}

    print(json.dumps(result, ensure_ascii=False, default=str))


async def mcp_main():
    """Run as MCP server over stdio."""
    from mcp.server import Server
    from mcp.server.stdio import stdio_server
    from mcp.types import Tool, TextContent

    server = Server("context-manager")

    @server.list_tools()
    async def list_tools():
        return [Tool(name=name, **defn) for name, defn in TOOLS.items()]

    @server.call_tool()
    async def call_tool(name: str, arguments: dict):
        project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
        ensure_schema(project_dir)

        handlers = {
            'memory_search': lambda: memory_search(project_dir, **arguments),
            'memory_store': lambda: memory_store(project_dir, **arguments),
            'memory_get': lambda: memory_get(project_dir, **arguments),
            'memory_update': lambda: memory_update(project_dir, **arguments),
            'memory_delete': lambda: memory_delete(project_dir, **arguments),
            'memory_list': lambda: memory_list(project_dir, **arguments),
            'memory_relation_create': lambda: memory_relation_create(project_dir, **arguments),
            'memory_relations_get': lambda: memory_relations_get(project_dir, **arguments),
            'memory_graph_get': lambda: memory_graph_get(project_dir, **arguments),
            'session_list': lambda: session_list(project_dir, **arguments),
            'session_get': lambda: session_get(project_dir, **arguments),
            'session_events': lambda: session_events(project_dir, **arguments),
            'decision_record': lambda: decision_record(project_dir, **arguments),
            'decision_list': lambda: decision_list(project_dir, **arguments),
            'pattern_register': lambda: pattern_register(project_dir, **arguments),
            'pattern_list': lambda: pattern_list(project_dir, **arguments),
            'preference_get': lambda: preference_get(project_dir, **arguments),
            'preference_set': lambda: preference_set(project_dir, **arguments),
            'stats_overview': lambda: stats_overview(project_dir),
            'briefing_generate': lambda: briefing_generate(project_dir, **arguments),
            'briefing_get': lambda: briefing_get(project_dir),
            'dedup_run': lambda: dedup_run(project_dir, **arguments),
            'decay_run': lambda: decay_run(project_dir),
        }

        handler = handlers.get(name)
        if not handler:
            return [TextContent(type="text", text=json.dumps({"error": f"Unknown: {name}"}))]

        try:
            result = handler()
            return [TextContent(type="text", text=json.dumps(result, ensure_ascii=False, default=str))]
        except Exception as e:
            return [TextContent(type="text", text=json.dumps({"error": str(e)}))]

    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--mcp":
        import asyncio
        asyncio.run(mcp_main())
    else:
        cli_main()
