"""Idempotent default-calendar seed for rustical's SQLite store.

Runs as an init container after `rustical principals list` has applied
the upstream sqlx migrations (so the schema exists). Writes are PK-keyed
with INSERT OR IGNORE so re-running on every pod start is a no-op.

Schema (rustical upstream, crates/store_sqlite/migrations/):
  principals(id PK, displayname, principal_type NOT NULL, password_hash)
  memberships(principal, member_of) -- composite PK, FK CASCADE
  calendars(principal, id, ..., push_topic UNIQUE NOT NULL,
            comp_event/_todo/_journal NOT NULL) -- PK (principal, id)

principal_type is stored as the uppercase form returned by rustical's
PrincipalType::as_str() ("INDIVIDUAL" / "GROUP"), not the lowercase serde
JSON form.

Sharing: rustical does not implement RFC 6638 share invites. The only
way two users can read/write a single calendar is for it to be owned by
a group principal of which they are both members. The shared calendar
here is owned by the configured group; both individuals are added to
the group's memberships.
"""

from __future__ import annotations

import os
import sqlite3
import sys
import uuid


def push_topic(principal: str, cal_id: str) -> str:
    # Deterministic UUID so re-runs hit the UNIQUE constraint cleanly via
    # INSERT OR IGNORE rather than producing a duplicate-key error.
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, f"rustical/{principal}/{cal_id}"))


def seed(
    con: sqlite3.Connection,
    *,
    personal: str,
    partner: str,
    group: str,
    group_displayname: str,
    personal_cal_id: str,
    personal_cal_name: str,
    shared_cal_id: str,
    shared_cal_name: str,
) -> None:
    principals = [
        (personal, None, "INDIVIDUAL"),
        (partner, None, "INDIVIDUAL"),
        (group, group_displayname, "GROUP"),
    ]
    memberships = [
        (personal, group),
        (partner, group),
    ]
    calendars = [
        (personal, personal_cal_id, personal_cal_name),
        (partner, personal_cal_id, personal_cal_name),
        (group, shared_cal_id, shared_cal_name),
    ]

    con.execute("PRAGMA foreign_keys = ON")
    with con:
        con.executemany(
            "INSERT OR IGNORE INTO principals (id, displayname, principal_type) VALUES (?, ?, ?)",
            principals,
        )
        con.executemany(
            "INSERT OR IGNORE INTO memberships (principal, member_of) VALUES (?, ?)",
            memberships,
        )
        for principal, cal_id, displayname in calendars:
            con.execute(
                """
                INSERT OR IGNORE INTO calendars
                  (principal, id, displayname, push_topic, comp_event, comp_todo, comp_journal)
                VALUES (?, ?, ?, ?, 1, 1, 1)
                """,
                (principal, cal_id, displayname, push_topic(principal, cal_id)),
            )


def main() -> int:
    db_path = os.environ["RUSTICAL_DB_PATH"]
    con = sqlite3.connect(db_path)
    try:
        seed(
            con,
            personal=os.environ["SEED_PERSONAL_USER"],
            partner=os.environ["SEED_PARTNER_USER"],
            group=os.environ["SEED_GROUP_ID"],
            group_displayname=os.environ["SEED_GROUP_DISPLAYNAME"],
            personal_cal_id=os.environ["SEED_PERSONAL_CAL_ID"],
            personal_cal_name=os.environ["SEED_PERSONAL_CAL_NAME"],
            shared_cal_id=os.environ["SEED_SHARED_CAL_ID"],
            shared_cal_name=os.environ["SEED_SHARED_CAL_NAME"],
        )
    finally:
        con.close()
    print("rustical seed: ok", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
