#!/usr/bin/env python3
"""v4.5: Extract tool event fields from stdin JSON → KEY=VALUE lines for bash.
Replaces sed-based extraction in post-tool.sh. Single stdin read, zero deps."""
import sys, json

# Force LF-only line endings to avoid Windows CRLF corrupting bash parsing
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(newline='\n')

raw = sys.stdin.buffer.read()
if not raw.strip():
    print('TOOL_NAME=')
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    print('TOOL_NAME=')
    sys.exit(0)

tool_name = data.get('tool_name', '')
print(f'TOOL_NAME={tool_name}')

ti = data.get('tool_input', {})
file_path = ti.get('file_path', '') or data.get('file_path', '')
print(f'FILE_PATH={file_path}')

# Summary: first non-empty field from prioritized list
summary = ''
for key in ['file_path', 'command', 'description', 'pattern', 'url',
            'query', 'skill', 'subject', 'taskId', 'cron', 'id']:
    val = ti.get(key)
    if val:
        # Sanitize: strip newlines, tabs, truncate (safe for JSON embedding)
        summary = str(val).replace('\n', ' ').replace('\r', ' ').replace('\t', ' ')[:200]
        break
if not summary:
    summary = '-'

# TaskCreate/Update: store full tool_input as ASCII-safe JSON for analytics
if tool_name in ('TaskCreate', 'TaskUpdate'):
    summary = json.dumps(ti, ensure_ascii=True)[:500]

print(f'SUMMARY={summary}')

exit_code = data.get('exit_code')
print(f'EXIT_CODE={exit_code}' if exit_code is not None else 'EXIT_CODE=')

stderr_raw = ti.get('stderr', '') or ''
if stderr_raw:
    stderr_summary = stderr_raw.replace('\n', ' ').replace('\r', ' ')[:200]
    print(f'STDERR_SUMMARY={stderr_summary}')
else:
    print('STDERR_SUMMARY=')
