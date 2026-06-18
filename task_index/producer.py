"""Resolve a task_id for a session from explicit env or the first prompt.
Deterministic only — never semantic/embedding inference (rejected by the
2026-06-17 task-inference backtest)."""
from __future__ import annotations

import re

# Tool-internal / automation prompts that are NOT trackable work (~64% of the
# claude-mem corpus). Lowercased startswith match.
_AUTOMATION_PREFIXES = (
    "# generate commit message",
    "you are executing one jira",
    "you are a fast triage router for jira",
    "you triage entries for a personal dotfiles",
    "explain the following like i am five",
    "rewrite shell command",
    "<ide_opened_file>",
    "is claude-mem hook working",
    "/parallel-agents assign",
)

# Allow-listed ticket prefixes (NOT a bare [A-Z]+-\d+, which catches UTF-8/SHA-256).
_TICKET_RE = re.compile(r"\b(SASSC-\d+|AELDEV-\d+)\b")
# A spec/plan doc slug: 2026-06-16-prior-work-index-design.md -> 2026-06-16-prior-work-index
_SLUG_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2}-[a-z0-9][a-z0-9-]*?)(?:-design|-plan)?\.md\b")


def is_work_session(prompt: str | None) -> bool:
    """False for empty/automation prompts; True for trackable work."""
    if not prompt:
        return False
    s = prompt.strip().lower()
    if len(s) < 8:
        return False
    return not any(s.startswith(p) for p in _AUTOMATION_PREFIXES)


def extract_task_id(prompt: str | None) -> str | None:
    """Deterministically pull a task id: ticket key first, then a spec/plan
    slug (design+plan of one feature normalize to the same id)."""
    if not prompt:
        return None
    m = _TICKET_RE.search(prompt)
    if m:
        return m.group(1).upper()
    m = _SLUG_RE.search(prompt)
    if m:
        return m.group(1)
    return None


def resolve_task_id(env: dict, prompt: str | None) -> str | None:
    """env $TASK_ID wins (explicit / inherited). Else, for a work session,
    extract from the prompt. Else None (the session stays cwd-keyed)."""
    explicit = (env.get("TASK_ID") or "").strip()
    if explicit:
        return explicit
    if not is_work_session(prompt):
        return None
    return extract_task_id(prompt)
