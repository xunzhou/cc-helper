from task_index import store


def test_upsert_and_query_ordered_by_time(tmp_path):
    conn = store.connect(str(tmp_path / "t.db"))
    store.upsert_session(conn, content_session_id="s2", task_id="SASSC-6260",
                         project="hq", started_at_epoch=200, source="env")
    store.upsert_session(conn, content_session_id="s1", task_id="SASSC-6260",
                         project="devops", started_at_epoch=100, source="extract")
    rows = store.sessions_for_task(conn, "SASSC-6260")
    assert [r["content_session_id"] for r in rows] == ["s1", "s2"]
    assert rows[0]["project"] == "devops"


def test_upsert_is_idempotent_by_session(tmp_path):
    conn = store.connect(str(tmp_path / "t.db"))
    store.upsert_session(conn, content_session_id="s1", task_id="A",
                         project="p", started_at_epoch=1, source="extract")
    store.upsert_session(conn, content_session_id="s1", task_id="B",
                         project="p", started_at_epoch=1, source="env")
    assert store.sessions_for_task(conn, "A") == []
    assert len(store.sessions_for_task(conn, "B")) == 1


def test_extract_never_overwrites_explicit_env(tmp_path):
    conn = store.connect(str(tmp_path / "t.db"))
    store.upsert_session(conn, content_session_id="s1", task_id="EXPLICIT-1",
                         project="p", started_at_epoch=1, source="env")
    store.upsert_session(conn, content_session_id="s1", task_id="GUESS-2",
                         project="p", started_at_epoch=1, source="extract")
    assert len(store.sessions_for_task(conn, "EXPLICIT-1")) == 1   # env preserved
    assert store.sessions_for_task(conn, "GUESS-2") == []


def test_db_path_honors_env(monkeypatch):
    monkeypatch.setenv("TASK_INDEX_DB", "/tmp/custom-tasks.db")
    assert store.db_path() == "/tmp/custom-tasks.db"
