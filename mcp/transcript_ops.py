#!/usr/bin/env python3
"""Transcript parsing — extract context from transcript.jsonl for session recovery.
v5.2: enriches briefing_generate with what was actually discussed.
Zero LLM cost — pure JSONL parsing + keyword extraction.
"""

import json
import os
import re
from typing import Optional
from collections import Counter
from datetime import datetime


# Keywords to ignore (too common to be meaningful)
_STOP_WORDS = {
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'could',
    'should', 'may', 'might', 'can', 'shall', 'to', 'of', 'in', 'for',
    'on', 'with', 'at', 'by', 'from', 'as', 'into', 'through', 'during',
    'before', 'after', 'above', 'below', 'between', 'and', 'but', 'or',
    'not', 'no', 'if', 'then', 'else', 'when', 'where', 'why', 'how',
    'this', 'that', 'these', 'those', 'it', 'its', 'we', 'you', 'he',
    'she', 'they', 'them', 'me', 'us', 'i', 'my', 'our', 'your', 'his',
    'her', 'their', 'just', 'very', 'really', 'also', 'too', 'only',
    'now', 'here', 'there', 'all', 'some', 'any', 'each', 'every',
    'which', 'what', 'who', 'whom', 'so', 'up', 'out', 'about',
    'get', 'got', 'make', 'made', 'need', 'like', 'use', 'one', 'two',
    'see', 'know', 'think', 'want', 'look', 'still', 'well', 'back',
    'even', 'way', 'much', 'many', 'more', 'most', 'go', 'going',
    'let', 'put', 'set', 'run', 'take', 'done', 'using', 'used',
}


def parse_transcript(transcript_path: str,
                     max_messages: int = 5,
                     max_files: int = 10) -> dict:
    """Parse Claude transcript.jsonl, extract key context for session recovery.

    Args:
        transcript_path: Path to transcript.jsonl from Stop hook
        max_messages: Number of last user messages to keep
        max_files: Max file paths to track

    Returns dict with:
        message_count, last_messages, tools_used, files_mentioned, topic_keywords,
        has_transcript, parsed_at
    """
    if not transcript_path or not os.path.exists(transcript_path):
        return {"has_transcript": False, "error": "transcript not found"}

    messages = []       # user text messages
    tool_names = []     # all tool names used
    file_paths = set()  # unique file paths
    line_errors = 0
    line_count = 0

    try:
        with open(transcript_path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                line_count += 1
                if not line.strip():
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    line_errors += 1
                    continue

                # User messages
                role = entry.get('role', '')
                if role == 'user':
                    content = entry.get('content', '')
                    if isinstance(content, list):
                        # Content blocks format
                        text_parts = []
                        for block in content:
                            if isinstance(block, dict) and block.get('type') == 'text':
                                text_parts.append(block.get('text', ''))
                        content = ' '.join(text_parts)
                    if isinstance(content, str) and content.strip():
                        messages.append(content.strip())

                # Assistant messages may contain tool_use blocks
                if role == 'assistant':
                    content = entry.get('content', [])
                    if isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get('type') == 'tool_use':
                                tool_names.append(block.get('name', ''))
                                inp = block.get('input', {})
                                if isinstance(inp, dict):
                                    fp = inp.get('file_path') or inp.get('path') or inp.get('filePath')
                                    if fp:
                                        file_paths.add(fp)

                # Top-level tool_use events (alternate format)
                if entry.get('type') == 'tool_use':
                    tool_names.append(entry.get('name', ''))
                    inp = entry.get('input', {})
                    if isinstance(inp, dict):
                        fp = inp.get('file_path') or inp.get('path') or inp.get('filePath')
                        if fp:
                            file_paths.add(fp)

    except Exception as e:
        return {"has_transcript": False, "error": f"parse error: {e}"}

    # Extract last N messages (trim to reasonable length for briefing injection)
    last_messages = messages[-max_messages:] if len(messages) > max_messages else messages
    last_messages = [m[:300] for m in last_messages]  # cap per-message length

    # Extract keywords from all messages
    all_text = ' '.join(messages)
    keywords = _extract_keywords(all_text)

    # Top tools
    tool_freq = Counter(tool_names).most_common(10)

    return {
        "has_transcript": True,
        "message_count": len(messages),
        "last_messages": last_messages,
        "tools_used": [t[0] for t in tool_freq],
        "tool_count": len(tool_names),
        "files_mentioned": sorted(file_paths)[:max_files],
        "topic_keywords": keywords,
        "line_count": line_count,
        "line_errors": line_errors,
        "parsed_at": datetime.now().isoformat(),
    }


def _extract_keywords(text: str, top_n: int = 8) -> list:
    """Simple keyword extraction — word frequency minus stop words.
    Focuses on technical terms (CamelCase, snake_case, dot.paths) and nouns."""
    # Technical tokens (file names, function names, paths)
    tech_tokens = re.findall(r'\b[a-zA-Z_][a-zA-Z0-9_./-]{2,}\b', text)
    tech_counter = Counter(t for t in tech_tokens
                          if t.lower() not in _STOP_WORDS
                          and len(t) > 2
                          and not t.isdigit())

    # Get top technical terms, weighted toward longer terms (more specific)
    scored = []
    for word, count in tech_counter.most_common(top_n * 3):
        if count < 2:
            continue
        # Longer terms are more specific
        score = count * min(len(word) / 4, 2.0)
        scored.append((word, score))

    scored.sort(key=lambda x: x[1], reverse=True)
    return [w for w, _ in scored[:top_n]]


# ═══════════════════════════════════════════════════════════════
# Briefing enrichment — merges transcript data into session context
# ═══════════════════════════════════════════════════════════════

def enrich_briefing(project_dir: Optional[str] = None,
                    transcript_path: Optional[str] = None) -> dict:
    """Parse transcript and store enriched context in session_notes.
    Returns summary for hook logging."""
    if not transcript_path:
        return {"status": "no_transcript_path"}

    parsed = parse_transcript(transcript_path)
    if not parsed.get('has_transcript'):
        return {"status": "parse_failed", "error": parsed.get('error')}

    # Store as a preference so briefing_generate can use it
    from db_core import get_db
    with get_db(project_dir) as conn:
        # Find current session
        row = conn.execute(
            "SELECT id FROM sessions WHERE status='active' ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
        if row:
            # Store transcript summary as context_summary on session
            summary_parts = []
            if parsed.get('last_messages'):
                last_msg = parsed['last_messages'][-1] if parsed['last_messages'] else ''
                if last_msg:
                    summary_parts.append(f"Last: {last_msg[:200]}")
            if parsed.get('topic_keywords'):
                summary_parts.append(f"Topics: {', '.join(parsed['topic_keywords'][:5])}")
            if parsed.get('tools_used'):
                summary_parts.append(f"Tools: {', '.join(parsed['tools_used'][:5])}")

            summary = '; '.join(summary_parts) if summary_parts else ''
            if summary:
                conn.execute(
                    "UPDATE sessions SET context_summary=? WHERE id=?",
                    (summary[:500], row['id'])
                )

    return {
        "status": "enriched",
        "keywords": parsed.get('topic_keywords', [])[:5],
        "messages": len(parsed.get('last_messages', [])),
        "tools": len(parsed.get('tools_used', [])),
    }
