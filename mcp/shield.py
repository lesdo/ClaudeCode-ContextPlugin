#!/usr/bin/env python3
"""AgentShield security scan — v0.2.0: secrets(14) active, 4 categories planned.
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
_patterns_compiled = None


def _get_patterns():
    global _patterns_compiled
    if _patterns_compiled is None:
        _patterns_compiled = [
            (_re.compile(p, _re.IGNORECASE if '(?i)' in p else 0), name, sev)
            for p, name, sev in _SECRETS_RULES
        ]
    return _patterns_compiled


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
    {"id": "permissions", "rules": 10, "available": False,
     "description": "Wildcard Bash, missing deny lists, dangerous flag combinations"},
    {"id": "hooks", "rules": 34, "available": False,
     "description": "Command injection, data exfiltration, silent error suppression"},
    {"id": "mcp", "rules": 23, "available": False,
     "description": "Supply-chain typosquatting, unpinned npx, hardcoded MCP config secrets"},
    {"id": "agents", "rules": 25, "available": False,
     "description": "Prompt injection, zero-width chars, time bombs, jailbreak vectors"},
]


# ═══════════════════════════════════════════════════════════════
# Public API
# ═══════════════════════════════════════════════════════════════

def security_scan(project_dir: Optional[str] = None,
                  categories: Optional[list] = None) -> dict:
    """Run security scan. Only secrets(14) fully implemented; 4 categories planned.

    Returns dict with findings[] per category, scan_summary, and opus_pipeline flag.
    ax6: all file-read errors caught — a single unreadable file won't abort the scan.
    """
    project_dir = project_dir or _os.getcwd()

    if categories:
        active_cats = [c for c in _ALL_CATEGORIES if c["id"] in categories]
    else:
        active_cats = list(_ALL_CATEGORIES)

    findings = []
    files_scanned = 0
    errors = []

    for cat in active_cats:
        if cat["id"] == "secrets" and cat["available"]:
            secrets_findings, scanned, errs = _scan_secrets(project_dir)
            for f in secrets_findings:
                f["category"] = "secrets"
            findings.extend(secrets_findings)
            files_scanned += scanned
            errors.extend(errs)

    # Count by severity
    severity_counts = {"critical": 0, "high": 0, "medium": 0, "low": 0}
    for f in findings:
        sev = f.get("severity", "low")
        severity_counts[sev] = severity_counts.get(sev, 0) + 1

    return {
        "status": "completed",
        "version": "0.2.0",
        "planned_rules": sum(c["rules"] for c in _ALL_CATEGORIES),
        "implemented_rules": sum(c["rules"] for c in _ALL_CATEGORIES if c["available"]),
        "categories": [{"id": c["id"], "rules": c["rules"], "available": c["available"]}
                       for c in active_cats],
        "opus_pipeline": False,
        "auto_fix": False,
        "findings": findings,
        "scan_summary": {
            "files_scanned": files_scanned,
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


def _scan_secrets(project_dir: str) -> tuple:
    """Scan project files for 14 types of hardcoded secrets.
    Returns (findings: list, files_scanned: int, errors: list).
    ax6: all per-file exceptions caught — one bad file won't stop scanning.
    """
    findings = []
    files_scanned = 0
    errors = []
    patterns = _get_patterns()

    for root, dirs, files in _os.walk(project_dir):
        # ax6: filter in-place to avoid descending into ignored dirs
        dirs[:] = [d for d in dirs if _should_scan_dir(d)]

        for fname in files:
            if files_scanned >= _MAX_FILES:
                return findings, files_scanned, errors

            if not _should_scan_file(fname):
                continue

            fpath = _os.path.join(root, fname)
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
                                    # ax6: truncate match context to 120 chars
                                    "context": line.strip()[:120],
                                })
                files_scanned += 1
            except Exception as e:
                errors.append(f"read_error:{_os.path.relpath(fpath, project_dir)}:{e}")

    return findings, files_scanned, errors
