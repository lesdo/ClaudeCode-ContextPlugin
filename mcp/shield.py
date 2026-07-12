#!/usr/bin/env python3
"""AgentShield security scan — v1.0.0: all 5 categories active (47 rules).
ECC-inspire: static rules + Opus adversarial pipeline (Red/Blue/Auditor) deferred.
ax4: thresholds env-configurable. ax6: fail-safe — scan errors never crash.
"""

import os as _os
import re as _re
from typing import Optional

# ═══════════════════════════════════════════════════════════════
# Scan config — env-configurable (ax4)
# ═══════════════════════════════════════════════════════════════

_IGNORE_DIRS = set(
    _os.environ.get('CP_SHIELD_IGNORE_DIRS',
        '.git,node_modules,__pycache__,.venv,venv,.tox,dist,build,.egg-info,'
        'archive,.claude/context,.context').split(',')
)
# Self-referential: rule description strings match their own patterns
_SELF_IGNORE_FILES = {'mcp/shield.py'}
_MAX_FILE_KB = int(_os.environ.get('CP_SHIELD_MAX_FILE_KB', '512'))
_MAX_FILES = int(_os.environ.get('CP_SHIELD_MAX_FILES', '5000'))
_SCAN_EXTENSIONS = set(
    _os.environ.get('CP_SHIELD_EXTENSIONS',
        '.py,.sh,.bash,.js,.ts,.jsx,.tsx,.json,.yaml,.yml,.toml,.env,.cfg,.ini,.conf,'
        '.md,.txt,.rb,.go,.rs,.java,.kt,.swift,.c,.cpp,.h,.hpp,.php,.rb,.pl'
    ).split(',')
)

# ═══════════════════════════════════════════════════════════════
# Secrets patterns (14 rules) — each: (regex, name, severity)
# ═══════════════════════════════════════════════════════════════

_SECRETS_RULES = [
    # 1. AWS Access Key ID
    (r'AKIA[0-9A-Z]{16}', 'AWS Access Key ID', 'critical'),
    # 2. AWS Secret Access Key (heuristic: 40-char base64-like near "secret")
    (r'(?i)(?:aws|access)[\s_\-]*secret[\s_\-]*(?:key|token)?[\s:=]+[\x27\x22]?([0-9a-zA-Z/+]{40})[\x27\x22]?',
     'AWS Secret Key (heuristic)', 'critical'),
    # 3. GitHub Personal Access Token (classic)
    (r'ghp_[0-9a-zA-Z]{36}', 'GitHub PAT (classic)', 'critical'),
    # 4. GitHub Fine-grained PAT
    (r'github_pat_[0-9a-zA-Z_]{22,82}', 'GitHub PAT (fine-grained)', 'critical'),
    # 5. Google API Key
    (r'AIza[0-9A-Za-z\-_]{35}', 'Google API Key', 'critical'),
    # 6. Generic API key assignment (high confidence)
    (r'(?i)(?:api[_\s\-]*(?:key|secret|token)|secret[_\s\-]*key|access[_\s\-]*key)[\s:=]+[\x27\x22]([0-9a-zA-Z\-_+/=]{16,})[\x27\x22]',
     'Generic API Key assignment', 'high'),
    # 7. Private key header (PEM)
    (r'-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----',
     'Private Key (PEM header)', 'critical'),
    # 8. JWT token pattern
    (r'eyJ[0-9a-zA-Z\-_]{10,}\.[0-9a-zA-Z\-_]{10,}\.[0-9a-zA-Z\-_]{10,}',
     'JWT Token', 'high'),
    # 9. Database connection string with credentials
    (r'(?:mongodb|postgres(?:ql)?|mysql|redis|sqlserver)://[^/\s]*@',
     'Database Connection String (credentials in URL)', 'critical'),
    # 10. Password in URL
    (r'://[^:/\s]+:[^@/\s]+@',
     'Password in URL', 'high'),
    # 11. Slack token
    (r'xox[baprs]-[0-9a-zA-Z\-]{10,}', 'Slack Token', 'high'),
    # 12. Stripe live key
    (r'sk_live_[0-9a-zA-Z]{24,}', 'Stripe Live Key', 'critical'),
    # 13. Generic token/bearer assignment
    (r'(?i)(?:token|bearer|auth)[\s:=]+[\x27\x22]([0-9a-zA-Z\-_+/=]{20,})[\x27\x22]',
     'Generic Token assignment', 'medium'),
    # 14. Long base64-like string — but exclude separator/banner lines
    (r'(?<![0-9a-zA-Z\-_+/=])[0-9a-zA-Z+/]{44,}={0,2}(?![0-9a-zA-Z\-_+/=])',
     'Long base64 string (potential secret)', 'low'),
]

# Compiled patterns cached after first use
_secrets_compiled = None
_permissions_compiled = None
_hooks_compiled = None
_mcp_compiled = None
_agents_compiled = None


def _compile_rules(rules_list, cache_var_name):
    """Lazy-compile regex rules. Each rule: (pattern_str, name, severity)."""
    global _secrets_compiled, _permissions_compiled
    cache = globals().get(cache_var_name)
    if cache is None:
        cache = [
            (_re.compile(p, _re.IGNORECASE if '(?i)' in p else 0), name, sev)
            for p, name, sev in rules_list
        ]
        globals()[cache_var_name] = cache
    return cache


# ═══════════════════════════════════════════════════════════════
# Permissions patterns (10 rules) — dangerous tool/script permissions
# ═══════════════════════════════════════════════════════════════

_PERMISSIONS_RULES = [
    # 1. Sandbox disabled in tool call
    (r'dangerouslyDisableSandbox\s*[=:]\s*true',
     'Sandbox disabled (dangerouslyDisableSandbox=true)', 'critical'),
    # 2. Wildcard recursive delete in Bash tool
    (r'(?:Bash|bash)\(["\x27].*rm\s+(?:-rf?\s+[\*\/]|-r\s+-f\s+[\*\/])',
     'Wildcard recursive delete (Bash rm -rf *)', 'critical'),
    # 3. Background execution without timeout
    (r'run_in_background\s*[=:]\s*true(?!.*timeout)',
     'Background execution without timeout guard', 'high'),
    # 4. Sudo usage in shell scripts (non-comment)
    (r'^\s*sudo\s+(?!.*(?:echo|print|comment|#))',
     'Sudo execution in script', 'high'),
    # 5. World-writable permission
    (r'chmod\s+(?:777|a\+rwx|ugo\+rwx)',
     'World-writable permission (chmod 777)', 'high'),
    # 6. Empty deny list in permissions config
    (r'"deny"\s*:\s*\[\s*\]',
     'Empty deny list in permissions', 'medium'),
    # 7. Wildcard allow permission
    (r'"allow"\s*:\s*\[\s*"(?:\*|https?://\*|\.\*)"',
     'Wildcard allow permission', 'high'),
    # 8. Command substitution in source/include path (bash dot-command or source)
    (r'(?:^|\s|;)(?:source\s+\$\(|\.\s+\S+\s*\$\(|source\s+\`)',
     'Command substitution in source/include path', 'high'),
    # 9. Hardcoded temp path (race condition risk)
    (r'(?:>|>>|cp\s|mv\s|cat\s.*>)\s*/tmp/[a-zA-Z_]',
     'Hardcoded /tmp/ path (temp file race risk)', 'low'),
    # 10. curl/wget without fail-flag (silent failure risk)
    (r'\bcurl\s+(?!.*(?:--fail|-f|--retry|--max-time))',
     'curl without --fail flag (silent failure risk)', 'low'),
]

# ═══════════════════════════════════════════════════════════════
# Hook security patterns (12 rules) — shell injection + data safety
# ═══════════════════════════════════════════════════════════════

_HOOKS_RULES = [
    # 1. eval with variable — command injection vector
    (r'(?:^|\s|;|&&|\|\|)\s*eval\s+\$',
     'eval with variable (command injection)', 'critical'),
    # 2. curl piped to shell — remote code execution
    (r'curl\s+\S+\s*\|\s*(?:bash|sh|/bin/bash|/bin/sh)',
     'curl-pipe-bash (remote code execution)', 'critical'),
    # 3. rm -rf with variable — dangerous cleanup
    (r'(?:^|\s|;)(?:\\)?rm\s+(?:-rf?\s+|--recursive\s+)\$',
     'rm -rf with variable (dangerous cleanup)', 'critical'),
    # 4. Python bare except: pass — silent error suppression (ax6 violation)
    (r'except\s*:\s*pass\b',
     'Bare except: pass (silent error suppression)', 'medium'),
    # 5. exec with unquoted variable (dangerous: path could be hijacked)
    (r'(?:^|\s|;)(?<!#)\bexec\s+\$[A-Za-z_][A-Za-z0-9_]*\b',
     'exec with unquoted variable path', 'high'),
    # 6. Variable redirected to file (not fd redirect 2>/dev/null)
    (r'(?:>|>>)\s*\$[A-Za-z_][A-Za-z0-9_]*\b',
     'Unquoted variable in file redirection', 'high'),
    # 7. wget piped to shell — remote code execution variant
    (r'wget\s+\S+\s*-O\s*-\s*\|\s*(?:bash|sh)',
     'wget-pipe-bash (remote code execution)', 'critical'),
    # 8. Git clone piped to shell — supply chain attack vector
    (r'git\s+clone\s+\S+\s*\|\s*(?:bash|sh)',
     'git-clone-pipe-bash (supply chain)', 'critical'),
    # 9. xargs without -0 (whitespace splitting risk)
    (r'xargs\s+(?!.*(?:-0|--null))\b',
     'xargs without --null flag', 'low'),
    # 11. find -exec with variable
    (r'find\s+.*-exec\s+.*\$',
     'find -exec with variable', 'high'),
    # 12. source/include with unquoted variable
    (r'(?:source|\.)\s+\$[A-Za-z_][A-Za-z0-9_]*\b',
     'source/include with unquoted variable path', 'high'),
]

# ═══════════════════════════════════════════════════════════════
# MCP supply-chain patterns (6 rules)
# ═══════════════════════════════════════════════════════════════

_MCP_RULES = [
    # 1. npx without version pin in MCP config
    (r'"command"\s*:\s*"npx"\s*,\s*"args"\s*:\s*\[\s*"(?!.*@)',
     'MCP npx without version pin', 'high'),
    # 2. uvx without version pin in MCP config
    (r'"command"\s*:\s*"uvx"\s*,\s*"args"\s*:\s*\[\s*"(?!.*@)',
     'MCP uvx without version pin', 'high'),
    # 3. pip install without hash verification
    (r'pip\d?\s+install\s+(?!(?:.*--hash|.*--require-hashes|.*--no-deps\b))',
     'pip install without hash verification', 'medium'),
    # 4. npm install -g (global install, supply chain risk)
    (r'npm\s+(?:i|install)\s+-g\b',
     'npm global install (supply chain risk)', 'medium'),
    # 5. MCP server config with raw GitHub URL
    (r'"url"\s*:\s*"https?://raw\.githubusercontent\.com/',
     'MCP server from raw GitHub URL (unpinned)', 'medium'),
    # 6. container image without digest (floating tag)
    (r'(?:image|container)\s*:\s*"?\S+:(?:latest|dev|staging)"?',
     'Container image with floating tag', 'low'),
]

# ═══════════════════════════════════════════════════════════════
# Agent prompt-safety patterns (6 rules)
# ═══════════════════════════════════════════════════════════════

_AGENTS_RULES = [
    # 1-4. Zero-width / bidirectional override chars (supply-chain attack vectors)
    ('​', 'Zero-width space (U+200B) — potential prompt injection', 'critical'),
    ('‌', 'Zero-width non-joiner (U+200C)', 'critical'),
    ('‍', 'Zero-width joiner (U+200D)', 'critical'),
    ('‮', 'Right-to-left override (U+202E) — bidirectional attack', 'critical'),
    # 5. Prompt injection override phrases
    (r'(?i)(?:ignore\s+(?:all\s+)?(?:previous|above|prior)\s+(?:instructions?|prompts?|rules?|constraints?)|'
     r'you\s+are\s+now\s+(?:DAN|jailbroken)|developer\s+mode\s+(?:enabled|activated))',
     'Prompt injection / jailbreak phrase', 'critical'),
    # 6. base64 decode piped to execution (obfuscated command)
    (r'base64\s+(?:-d|--decode)\s*\|\s*(?:bash|sh|eval|\$SHELL)',
     'base64 decode piped to shell execution', 'high'),
]


# ═══════════════════════════════════════════════════════════════
# False-positive filters
# ═══════════════════════════════════════════════════════════════

def _is_separator_line(line: str) -> bool:
    """Detect comment separators, banners, divider lines — not secrets."""
    stripped = line.strip()
    if not stripped:
        return True
    # Lines dominated by a single repeating char (===, ---, ###, ///)
    for ch in '=-#/\\*_═╔╗╚╝║╠╣╦╩╬':
        if stripped.count(ch) > len(stripped) * 0.7 and len(stripped) > 8:
            return True
    return False


# ═══════════════════════════════════════════════════════════════
# Category metadata
# ═══════════════════════════════════════════════════════════════

_ALL_CATEGORIES = [
    {"id": "secrets", "rules": 14, "available": True,
     "description": "API keys, tokens, connection strings, private keys, base64 secrets"},
    {"id": "permissions", "rules": 10, "available": True,
     "description": "Dangerous Bash flags, sandbox disable, wildcard permissions, sudo/chmod abuse"},
    {"id": "hooks", "rules": 11, "available": True,
     "description": "Command injection, pipe-to-shell, bare except, unsafe redirection"},
    {"id": "mcp", "rules": 6, "available": True,
     "description": "Unpinned npx/uvx, pip without hash, raw GitHub URLs, floating container tags"},
    {"id": "agents", "rules": 6, "available": True,
     "description": "Zero-width chars, prompt injection phrases, base64-encoded shell exec"},
]


# ═══════════════════════════════════════════════════════════════
# Public API
# ═══════════════════════════════════════════════════════════════

def security_scan(project_dir: Optional[str] = None,
                  categories: Optional[list] = None) -> dict:
    """Run security scan across active categories.
    v1.0.0: all 5 categories active = 47 rules total.

    Returns dict with findings[] per category, scan_summary, and opus_pipeline flag.
    ax6: all file-read errors caught -- a single unreadable file won't abort the scan.
    """
    project_dir = project_dir or _os.getcwd()

    if categories:
        active_cats = [c for c in _ALL_CATEGORIES if c["id"] in categories]
    else:
        active_cats = list(_ALL_CATEGORIES)

    # Category scanner dispatch — each returns (findings, files_scanned, errors)
    _SCANNERS = {
        "secrets": lambda: _scan_category(project_dir, _SECRETS_RULES, "_secrets_compiled", "secrets"),
        "permissions": lambda: _scan_category(project_dir, _PERMISSIONS_RULES, "_permissions_compiled", "permissions"),
        "hooks": lambda: _scan_category(project_dir, _HOOKS_RULES, "_hooks_compiled", "hooks"),
        "mcp": lambda: _scan_category(project_dir, _MCP_RULES, "_mcp_compiled", "mcp"),
        "agents": lambda: _scan_category(project_dir, _AGENTS_RULES, "_agents_compiled", "agents"),
    }

    findings = []
    total_files = 0
    errors = []

    for cat in active_cats:
        if cat["available"] and cat["id"] in _SCANNERS:
            cat_findings, scanned, errs = _SCANNERS[cat["id"]]()
            findings.extend(cat_findings)
            total_files += scanned
            errors.extend(errs)

    # Count by severity
    severity_counts = {"critical": 0, "high": 0, "medium": 0, "low": 0}
    for f in findings:
        sev = f.get("severity", "low")
        severity_counts[sev] = severity_counts.get(sev, 0) + 1

    return {
        "status": "completed",
        "version": "1.0.0",
        "planned_rules": sum(c["rules"] for c in _ALL_CATEGORIES),
        "implemented_rules": sum(c["rules"] for c in _ALL_CATEGORIES if c["available"]),
        "categories": [{"id": c["id"], "rules": c["rules"], "available": c["available"]}
                       for c in active_cats],
        "opus_pipeline": False,
        "auto_fix": False,
        "findings": findings,
        "scan_summary": {
            "files_scanned": total_files,
            "total_findings": len(findings),
            "by_severity": severity_counts,
            "errors": len(errors),
        },
        "errors": errors[:20],  # cap error detail at 20
    }


# ═══════════════════════════════════════════════════════════════
# Internal scanners
# ═══════════════════════════════════════════════════════════════

def _should_scan_dir(dirname: str) -> bool:
    return dirname not in _IGNORE_DIRS and not dirname.startswith('.')


def _should_scan_file(filename: str) -> bool:
    _, ext = _os.path.splitext(filename)
    return ext.lower() in _SCAN_EXTENSIONS


def _scan_category(project_dir: str, rules_list: list, cache_name: str, cat_name: str) -> tuple:
    """Generic scanner: walk project, apply compiled rules, collect findings.
    Returns (findings: list, files_scanned: int, errors: list).
    ax6: all per-file exceptions caught — one bad file won't stop scanning.
    """
    findings = []
    files_scanned = 0
    errors = []
    patterns = _compile_rules(rules_list, cache_name)

    for root, dirs, files in _os.walk(project_dir):
        # ax6: filter in-place to avoid descending into ignored dirs
        dirs[:] = [d for d in dirs if _should_scan_dir(d)]

        for fname in files:
            if files_scanned >= _MAX_FILES:
                return findings, files_scanned, errors

            if not _should_scan_file(fname):
                continue

            fpath = _os.path.join(root, fname)
            rel = _os.path.relpath(fpath, project_dir)
            # Skip self-referential rule definition files
            if rel.replace('\\', '/') in _SELF_IGNORE_FILES:
                continue
            fsize = _os.path.getsize(fpath) if _os.path.exists(fpath) else 0
            if fsize > _MAX_FILE_KB * 1024:
                continue

            try:
                with open(fpath, 'r', encoding='utf-8', errors='replace') as fh:
                    rel = _os.path.relpath(fpath, project_dir)
                    for lineno, line in enumerate(fh, 1):
                        if _is_separator_line(line):
                            continue
                        for pattern, name, severity in patterns:
                            if pattern.search(line):
                                findings.append({
                                    "file": rel,
                                    "line": lineno,
                                    "rule": name,
                                    "severity": severity,
                                    "category": cat_name,
                                    "context": line.strip()[:120],
                                })
                files_scanned += 1
            except Exception as e:
                errors.append(f"read_error:{_os.path.relpath(fpath, project_dir)}:{e}")

    return findings, files_scanned, errors
