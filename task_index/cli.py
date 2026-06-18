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


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="task-index")
    p.add_argument("--db", default=None, help="sidecar DB (default ~/.claude-mem-tasks.db)")
    p.add_argument("--mem-db", default=None, help="claude-mem DB (opened read-only)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("build", help="index claude-mem history into the sidecar")
    args = p.parse_args(argv)
    return {"build": cmd_build}[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
