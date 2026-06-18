"""Sidecar SQLite mapping a Claude Code session -> its task_id. Additive;
claude-mem's own DB is never modified."""
from __future__ import annotations

import os
import sqlite3
import time
from pathlib import Path

DB_ENV = "TASK_INDEX_DB"
DEFAULT_DB = Path.home() / ".claude-mem-tasks.db"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS session_task (
    content_session_id TEXT PRIMARY KEY,
    task_id            TEXT NOT NULL,
    project            TEXT,
    started_at_epoch   INTEGER,
    source             TEXT NOT NULL,
    updated_at_epoch   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS session_task_task_idx ON session_task(task_id);
"""


def db_path() -> str:
    return os.environ.get(DB_ENV) or str(DEFAULT_DB)


def init_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(_SCHEMA)
    conn.commit()


def connect(path: str | None = None) -> sqlite3.Connection:
    conn = sqlite3.connect(path or db_path())
    conn.row_factory = sqlite3.Row
    init_schema(conn)
    return conn


def upsert_session(conn, *, content_session_id, task_id, project,
                   started_at_epoch, source) -> None:
    conn.execute(
        """INSERT INTO session_task
             (content_session_id, task_id, project, started_at_epoch, source, updated_at_epoch)
           VALUES (?, ?, ?, ?, ?, ?)
           ON CONFLICT(content_session_id) DO UPDATE SET
             task_id=excluded.task_id, project=excluded.project,
             started_at_epoch=excluded.started_at_epoch, source=excluded.source,
             updated_at_epoch=excluded.updated_at_epoch
           WHERE excluded.source='env' OR session_task.source!='env'""",
        (content_session_id, task_id, project, started_at_epoch, source, int(time.time())),
    )
    conn.commit()


def sessions_for_task(conn, task_id: str) -> list[sqlite3.Row]:
    return list(conn.execute(
        "SELECT content_session_id, project, started_at_epoch, source "
        "FROM session_task WHERE task_id = ? ORDER BY started_at_epoch", (task_id,)))
