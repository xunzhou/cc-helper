import io
import json
import sqlite3

from task_index import cli, store


def _fake_mem(path):
    c = sqlite3.connect(path)
    c.executescript(
        """CREATE TABLE sdk_sessions(content_session_id TEXT, memory_session_id TEXT,
              project TEXT, user_prompt TEXT, started_at_epoch INTEGER);
           CREATE TABLE observations(memory_session_id TEXT, project TEXT, type TEXT,
              title TEXT, created_at_epoch INTEGER);""")
    c.executemany("INSERT INTO sdk_sessions VALUES (?,?,?,?,?)", [
        ("cs1", "ms1", "cc-matrix", "work on SASSC-6260 first", 10),
        ("cs2", "ms2", "desktop-workflow", "more SASSC-6260 follow-up", 20),
        ("cs3", "ms3", "hq", "# Generate Commit Message (JSON) You are", 30),
    ])
    c.executemany("INSERT INTO observations VALUES (?,?,?,?,?)", [
        ("ms1", "cc-matrix", "feature", "did the thing", 11),
        ("ms2", "desktop-workflow", "bugfix", "fixed the other thing", 21),
    ])
    c.commit()
    c.close()


def test_build_indexes_work_sessions_only(tmp_path):
    mem = str(tmp_path / "mem.db"); side = str(tmp_path / "side.db"); _fake_mem(mem)
    assert cli.main(["--db", side, "--mem-db", mem, "build"]) == 0
    conn = store.connect(side)
    rows = store.sessions_for_task(conn, "SASSC-6260")
    assert [r["content_session_id"] for r in rows] == ["cs1", "cs2"]  # cs3 automation skipped


def test_recall_groups_activity_by_repo(tmp_path, capsys):
    mem = str(tmp_path / "mem.db"); side = str(tmp_path / "side.db"); _fake_mem(mem)
    cli.main(["--db", side, "--mem-db", mem, "build"])
    assert cli.main(["--db", side, "--mem-db", mem, "recall", "SASSC-6260"]) == 0
    out = capsys.readouterr().out
    assert "2 session(s) across 2 repo(s)" in out
    assert "cc-matrix" in out and "desktop-workflow" in out
    assert "did the thing" in out


def test_recall_unknown_task_is_graceful(tmp_path, capsys):
    mem = str(tmp_path / "mem.db"); side = str(tmp_path / "side.db"); _fake_mem(mem)
    assert cli.main(["--db", side, "--mem-db", mem, "recall", "NOPE-1"]) == 0
    assert "no sessions tagged NOPE-1" in capsys.readouterr().out


def test_capture_hook_tags_session_from_stdin(tmp_path, monkeypatch):
    side = str(tmp_path / "side.db")
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(
        {"session_id": "csX", "cwd": "/data/proj/hq", "prompt": "work on AELDEV-1 now"})))
    assert cli.main(["--db", side, "capture-hook"]) == 0
    conn = store.connect(side)
    rows = store.sessions_for_task(conn, "AELDEV-1")
    assert [r["content_session_id"] for r in rows] == ["csX"]


def test_capture_hook_ignores_bad_json(tmp_path, monkeypatch):
    side = str(tmp_path / "side.db")
    monkeypatch.setattr("sys.stdin", io.StringIO("not json"))
    assert cli.main(["--db", side, "capture-hook"]) == 0
