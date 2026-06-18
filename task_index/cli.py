"""task-index — build the sidecar from claude-mem history, capture live
sessions, and recall a task's activity across repos."""
from __future__ import annotations

import argparse
import os
import sqlite3
from pathlib import Path

from . import producer, store

MEM_DB_ENV = "CLAUDE_MEM_DB"
DEFAULT_MEM_DB = Path.home() / ".claude-mem" / "claude-mem.db"


def mem_db_path() -> str:
    return os.environ.get(MEM_DB_ENV) or str(DEFAULT_MEM_DB)


def _mem_connect(path: str | None = None) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{path or mem_db_path()}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def cmd_build(args) -> int:
    mem = _mem_connect(args.mem_db)
    side = store.connect(args.db)
    n = 0
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
    ids = [r["content_session_id"] for r in store.sessions_for_task(side, args.task_id)]
    if not ids:
        print(f"no sessions tagged {args.task_id}")
        return 0
    mem = _mem_connect(args.mem_db)
    placeholders = ",".join("?" * len(ids))
    rows = mem.execute(
        f"""SELECT s.project AS project, o.created_at_epoch AS ts,
                   o.type AS type, o.title AS title
            FROM sdk_sessions s JOIN observations o
              ON o.memory_session_id = s.memory_session_id
            WHERE s.content_session_id IN ({placeholders})
            ORDER BY s.project, o.created_at_epoch""", ids).fetchall()
    repos = sorted({r["project"] for r in rows})
    print(f"task {args.task_id} — {len(ids)} session(s) across {len(repos)} repo(s): "
          f"{', '.join(repos)}")
    current = None
    for r in rows:
        if r["project"] != current:
            current = r["project"]
            print(f"\n## {current}")
        print(f"  [{r['type']}] {r['title']}")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="task-index")
    p.add_argument("--db", default=None, help="sidecar DB (default ~/.claude-mem-tasks.db)")
    p.add_argument("--mem-db", default=None, help="claude-mem DB (opened read-only)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("build", help="index claude-mem history into the sidecar")
    rc = sub.add_parser("recall", help="show a task's activity across repos")
    rc.add_argument("task_id")
    args = p.parse_args(argv)
    return {"build": cmd_build, "recall": cmd_recall}[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
