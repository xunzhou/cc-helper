"""task-index — build the sidecar from claude-mem history, capture live
sessions, and recall a task's activity across repos."""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

from . import producer, store

MEM_DB_ENV = "CLAUDE_MEM_DB"
DEFAULT_MEM_DB = Path.home() / ".claude-mem" / "claude-mem.db"


def mem_db_path() -> str:
    return os.environ.get(MEM_DB_ENV) or str(DEFAULT_MEM_DB)


def _mem_connect(path: str | None = None) -> sqlite3.Connection:
    resolved = path or mem_db_path()
    try:
        conn = sqlite3.connect(f"file:{resolved}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        raise SystemExit(f"task-index: cannot open claude-mem DB (read-only) at {resolved!r}: {e}")
    conn.row_factory = sqlite3.Row
    return conn


def cmd_build(args) -> int:
    mem = _mem_connect(args.mem_db)
    side = store.connect(args.db)
    n = 0
    # Re-runs are idempotent (upsert by content_session_id) ONLY while the
    # producer stays pure: changing extractor rules would rewrite extract-sourced
    # rows on the next build. env-sourced rows are protected by the upsert WHERE.
    for row in mem.execute(
            "SELECT content_session_id, project, user_prompt, started_at_epoch "
            "FROM sdk_sessions WHERE content_session_id IS NOT NULL"):
        tid = producer.resolve_task_id({}, row["user_prompt"])
        if not tid:
            continue
        store.upsert_session(
            side, content_session_id=row["content_session_id"], task_id=tid,
            project=row["project"], started_at_epoch=row["started_at_epoch"],
            source="extract")
        n += 1
    print(f"indexed {n} sessions into {args.db or store.db_path()}")
    return 0


def cmd_recall(args) -> int:
    side = store.connect(args.db)
    sessions = store.sessions_for_task(side, args.task_id)
    if not sessions:
        print(f"no sessions tagged {args.task_id}")
        return 0
    ids = [r["content_session_id"] for r in sessions]
    mem = _mem_connect(args.mem_db)
    placeholders = ",".join("?" * len(ids))
    activity = mem.execute(
        f"""SELECT s.content_session_id AS sid, o.created_at_epoch AS ts,
                   o.type AS type, o.title AS title
            FROM sdk_sessions s JOIN observations o
              ON o.memory_session_id = s.memory_session_id
            WHERE s.content_session_id IN ({placeholders})
            ORDER BY o.created_at_epoch""", ids).fetchall()
    by_session = defaultdict(list)
    for a in activity:
        by_session[a["sid"]].append(a)
    by_repo = defaultdict(list)
    for r in sessions:
        by_repo[r["project"] or "(unknown)"].append(r)
    repos = sorted(by_repo)
    print(f"task {args.task_id} — {len(sessions)} session(s) across {len(repos)} repo(s): "
          f"{', '.join(repos)}")
    for repo in repos:
        print(f"\n## {repo}")
        for sess in by_repo[repo]:
            acts = by_session.get(sess["content_session_id"], [])
            if acts:
                for a in acts:
                    print(f"  [{a['type']}] {a['title']}")
            else:
                print(f"  (session {sess['content_session_id'][:8]} — no observations indexed)")
    return 0


def cmd_capture_hook(args) -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError, TypeError):
        return 0
    sid = payload.get("session_id")
    if not sid:
        return 0
    tid = producer.resolve_task_id(dict(os.environ), payload.get("prompt"))
    if not tid:
        return 0
    side = store.connect(args.db)
    store.upsert_session(
        side, content_session_id=sid, task_id=tid, project=payload.get("cwd"),
        started_at_epoch=None,
        source="env" if (os.environ.get("TASK_ID") or "").strip() else "extract")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="task-index")
    p.add_argument("--db", default=None, help="sidecar DB (default ~/.claude-mem-tasks.db)")
    p.add_argument("--mem-db", default=None, help="claude-mem DB (opened read-only)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("build", help="index claude-mem history into the sidecar")
    rc = sub.add_parser("recall", help="show a task's activity across repos")
    rc.add_argument("task_id")
    sub.add_parser("capture-hook", help="record one session from CC hook JSON on stdin")
    args = p.parse_args(argv)
    return {"build": cmd_build, "recall": cmd_recall,
            "capture-hook": cmd_capture_hook}[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
