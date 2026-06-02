"""Tests for rustical-seed.py.

Verifies the contracts that matter operationally:
  - fresh DB: principals + memberships + calendars all land
  - re-run: no duplicates, no errors (INSERT OR IGNORE)
  - push_topic is deterministic (so UNIQUE constraint survives re-runs)
  - principal_type values match rustical's uppercase storage form
  - shared calendar is owned by the group, not a user (sharing model)

Run with:

  uv run --with pytest pytest data/scripts/test_rustical_seed.py
"""
from __future__ import annotations

import importlib.util
import sqlite3
from pathlib import Path

import pytest


# Hyphenated filename -> can't `import rustical-seed`.
spec = importlib.util.spec_from_file_location(
    "rustical_seed", Path(__file__).parent / "rustical-seed.py"
)
assert spec is not None and spec.loader is not None
rustical_seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rustical_seed)


# Mirror of the rustical upstream schema (crates/store_sqlite/migrations/).
# Re-implementing the migrations here keeps the test independent of having
# the rustical binary available in CI.
SCHEMA = """
CREATE TABLE principals (
    id TEXT PRIMARY KEY NOT NULL,
    displayname TEXT,
    principal_type TEXT NOT NULL,
    password_hash TEXT
);
CREATE TABLE app_tokens (
    id TEXT PRIMARY KEY NOT NULL,
    principal TEXT NOT NULL REFERENCES principals(id) ON DELETE CASCADE,
    token TEXT NOT NULL,
    displayname TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE memberships (
    principal TEXT NOT NULL REFERENCES principals(id) ON DELETE CASCADE,
    member_of TEXT NOT NULL REFERENCES principals(id) ON DELETE CASCADE,
    PRIMARY KEY (principal, member_of)
);
CREATE TABLE calendars (
    principal TEXT NOT NULL,
    id TEXT NOT NULL,
    synctoken INTEGER DEFAULT 0 NOT NULL,
    displayname TEXT,
    description TEXT,
    "order" INT DEFAULT 0 NOT NULL,
    color TEXT,
    timezone TEXT,
    timezone_id TEXT,
    deleted_at DATETIME,
    subscription_url TEXT,
    push_topic TEXT UNIQUE NOT NULL,
    comp_event BOOLEAN NOT NULL,
    comp_todo BOOLEAN NOT NULL,
    comp_journal BOOLEAN NOT NULL,
    PRIMARY KEY (principal, id),
    CONSTRAINT fk_calendar_principal FOREIGN KEY (principal)
    REFERENCES principals (id) ON DELETE RESTRICT
);
"""


SEED_KWARGS = dict(
    personal="alice",
    partner="bob",
    group="household",
    group_displayname="Household",
    personal_cal_id="personal",
    personal_cal_name="Personal",
    shared_cal_id="taracal",
    shared_cal_name="TaraCal",
)


@pytest.fixture
def con():
    c = sqlite3.connect(":memory:")
    c.executescript(SCHEMA)
    yield c
    c.close()


def test_fresh_db_seeds_all_rows(con):
    rustical_seed.seed(con, **SEED_KWARGS)

    principals = sorted(con.execute("SELECT id, principal_type FROM principals").fetchall())
    assert principals == [
        ("alice", "INDIVIDUAL"),
        ("bob", "INDIVIDUAL"),
        ("household", "GROUP"),
    ]

    memberships = sorted(con.execute("SELECT principal, member_of FROM memberships").fetchall())
    assert memberships == [("alice", "household"), ("bob", "household")]

    calendars = sorted(
        con.execute("SELECT principal, id, displayname FROM calendars").fetchall()
    )
    assert calendars == [
        ("alice", "personal", "Personal"),
        ("bob", "personal", "Personal"),
        ("household", "taracal", "TaraCal"),
    ]


def test_shared_calendar_owned_by_group(con):
    # The sharing model in rustical is group-ownership. The shared calendar
    # must be owned by the group principal, not by a user — otherwise only
    # the owner can read/write.
    rustical_seed.seed(con, **SEED_KWARGS)
    owner = con.execute(
        "SELECT principal FROM calendars WHERE id = ?", ("taracal",)
    ).fetchone()
    assert owner == ("household",)


def test_required_calendar_columns_populated(con):
    rustical_seed.seed(con, **SEED_KWARGS)
    rows = con.execute(
        "SELECT push_topic, comp_event, comp_todo, comp_journal FROM calendars"
    ).fetchall()
    assert len(rows) == 3
    topics = {row[0] for row in rows}
    assert len(topics) == 3, "push_topic must be unique per calendar"
    for _, comp_event, comp_todo, comp_journal in rows:
        assert (comp_event, comp_todo, comp_journal) == (1, 1, 1)


def test_rerun_is_idempotent(con):
    rustical_seed.seed(con, **SEED_KWARGS)
    rustical_seed.seed(con, **SEED_KWARGS)
    rustical_seed.seed(con, **SEED_KWARGS)

    counts = {
        "principals": con.execute("SELECT COUNT(*) FROM principals").fetchone()[0],
        "memberships": con.execute("SELECT COUNT(*) FROM memberships").fetchone()[0],
        "calendars": con.execute("SELECT COUNT(*) FROM calendars").fetchone()[0],
    }
    assert counts == {"principals": 3, "memberships": 2, "calendars": 3}


def test_push_topic_is_deterministic():
    a = rustical_seed.push_topic("alice", "personal")
    b = rustical_seed.push_topic("alice", "personal")
    c = rustical_seed.push_topic("bob", "personal")
    assert a == b
    assert a != c


def test_preexisting_principal_is_not_overwritten(con):
    # Mimics the JIT-OIDC case: rustical's OIDC user store may have already
    # created the principal with its own displayname before our seed runs
    # (or vice-versa, on a fresh DB our seed creates it first and JIT later
    # finds AlreadyExists). Either way, the existing displayname stays.
    con.execute(
        "INSERT INTO principals (id, displayname, principal_type) VALUES (?, ?, ?)",
        ("alice", "Alice From OIDC", "INDIVIDUAL"),
    )
    con.commit()

    rustical_seed.seed(con, **SEED_KWARGS)

    displayname = con.execute(
        "SELECT displayname FROM principals WHERE id = ?", ("alice",)
    ).fetchone()[0]
    assert displayname == "Alice From OIDC"


def test_preexisting_calendar_is_not_overwritten(con):
    # If a user creates "Personal" themselves before the seed runs (unlikely
    # but possible across pod restarts), don't clobber their displayname.
    con.executescript(
        """
        INSERT INTO principals (id, principal_type) VALUES ('alice', 'INDIVIDUAL');
        INSERT INTO principals (id, principal_type) VALUES ('bob', 'INDIVIDUAL');
        INSERT INTO principals (id, principal_type) VALUES ('household', 'GROUP');
        INSERT INTO calendars
          (principal, id, displayname, push_topic, comp_event, comp_todo, comp_journal)
          VALUES ('alice', 'personal', 'My Stuff', 'pre-existing-topic', 1, 1, 1);
        """
    )
    con.commit()

    rustical_seed.seed(con, **SEED_KWARGS)

    displayname = con.execute(
        "SELECT displayname FROM calendars WHERE principal='alice' AND id='personal'"
    ).fetchone()[0]
    assert displayname == "My Stuff"
