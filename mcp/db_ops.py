#!/usr/bin/env python3
"""
Re-export wrapper — delegates to session_ops.py and memory_ops.py.
Kept for backward compatibility. New code should import from the split modules directly.
"""
from session_ops import (
    session_create, session_finalize, session_get, session_list,
    session_check_active, session_mark_abandoned,
    session_events, session_events_by_slug, session_compile_md,
    event_log,
    session_stats, session_find_status,
    stats_overview,
    briefing_generate, briefing_get,
    decay_run, dedup_run,
)
from session_ops import (
    memory_relation_create, memory_relations_get, memory_graph_get,
)
from memory_ops import (
    memory_search, memory_store, memory_get, memory_update,
    memory_delete, memory_list,
    memory_hybrid_search, memory_reindex_vectors,
    decision_record, decision_list,
    pattern_register, pattern_list,
    preference_get, preference_set,
)
