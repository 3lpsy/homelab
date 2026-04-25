"""Seeds Frigate's auth db with the Vault-managed admin password.

Frigate has no upstream CLI / env hook for password injection, so this
script talks to /config/frigate.db directly. It is run as an init
container before the main Frigate container starts, so the SQLite db
either already exists from a previous boot, or peewee creates it here.
Idempotent: re-running upserts the same row.

Reads the password from /mnt/secrets/admin_password (CSI Secret Store
mount, sourced from Vault `secret/frigate/config:admin_password`).

If Frigate moves the hash function in a future release, the fallback
re-implements its PBKDF2-SHA256 / 600k-iteration format so logins keep
working until the import path is updated.
"""

import sys

sys.path.insert(0, "/opt/frigate")

with open("/mnt/secrets/admin_password") as f:
    password = f.read().strip()
if not password:
    print("ERROR: /mnt/secrets/admin_password is empty", file=sys.stderr)
    sys.exit(1)

from peewee import SqliteDatabase
from frigate.models import User

hash_password = None
for mod_path in ("frigate.api.auth", "frigate.util.auth", "frigate.api.user"):
    try:
        mod = __import__(mod_path, fromlist=["hash_password"])
        fn = getattr(mod, "hash_password", None)
        if callable(fn):
            hash_password = fn
            break
    except ImportError:
        continue

if hash_password is None:
    import base64
    import hashlib
    import secrets as _s

    ITER = 600_000
    salt = _s.token_bytes(22)
    h = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, ITER)
    hashed = (
        f"pbkdf2:sha256:{ITER}$"
        f"{base64.b64encode(salt).decode()}$"
        f"{base64.b64encode(h).decode()}"
    )
    print("Used fallback PBKDF2 hash (frigate hash_password import failed)")
else:
    hashed = hash_password(password)

db = SqliteDatabase("/config/frigate.db")
User._meta.set_database(db)
db.connect()
db.create_tables([User], safe=True)
# notification_tokens has a NOT NULL constraint with a peewee-side default
# that on_conflict_replace bypasses; pass an empty list explicitly so the
# JSONField serializes to [] instead of NULL.
User.insert(
    username="admin",
    password_hash=hashed,
    notification_tokens=[],
).on_conflict_replace().execute()
db.close()
print("Seeded admin user from Vault")
