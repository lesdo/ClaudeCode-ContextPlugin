#!/usr/bin/env python3
"""User profile auto-generation from behavior_profile data.
Extracted from analytics.py — ax7: file complexity limit (584 > 500)."""

import os
import re
from datetime import datetime
from db_core import get_db


def update_user_md(project_dir: str) -> dict:
    """Read behavior_profile and generate/update the auto-segment
    in user.md. Only writes the <!-- auto --> block."""
    user_md_path = os.path.expanduser("~/.claude/profile/user.md")
    os.makedirs(os.path.dirname(user_md_path), exist_ok=True)

    if os.path.exists(user_md_path):
        with open(user_md_path, 'r', encoding='utf-8') as f:
            content = f.read()
    else:
        content = _default_user_md()

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
        edit_heavy = float(os.environ.get('CP_EDIT_HEAVY_RATIO', '3.0'))
        if ratio >= edit_heavy:
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

    auto_block = "\n".join(auto_lines)
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
