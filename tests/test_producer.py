from task_index import producer


def test_is_work_session_filters_automation_and_empties():
    assert producer.is_work_session("# Generate Commit Message (JSON)\nYou are a Git") is False
    assert producer.is_work_session("<ide_opened_file>/data/proj/hq/x") is False
    assert producer.is_work_session("   ") is False
    assert producer.is_work_session("test") is False
    assert producer.is_work_session("fix the auth bug in cc-matrix") is True


def test_extract_ticket_keys():
    assert producer.extract_task_id("/SASSC-tickets SASSC-6260 customer wants a list") == "SASSC-6260"
    assert producer.extract_task_id("look at AELDEV-69698 please") == "AELDEV-69698"


def test_extract_ignores_utf8_and_sha_false_positives():
    assert producer.extract_task_id("decode UTF-8 and verify SHA-256") is None


def test_extract_spec_slug_unifies_design_and_plan():
    d = producer.extract_task_id("pickup 2026-06-16-prior-work-index-design.md")
    p = producer.extract_task_id("execute /data/proj/hq/2026-06-16-prior-work-index-plan.md")
    assert d == p == "2026-06-16-prior-work-index"


def test_resolve_env_wins_even_for_automation():
    assert producer.resolve_task_id({"TASK_ID": "FOO-1"}, "# Generate Commit Message") == "FOO-1"


def test_resolve_extracts_when_no_env_else_none():
    assert producer.resolve_task_id({}, "work on SASSC-6260 today") == "SASSC-6260"
    assert producer.resolve_task_id({}, "just chatting about nothing in particular") is None
