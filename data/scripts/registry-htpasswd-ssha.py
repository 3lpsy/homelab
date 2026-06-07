#!/usr/bin/env python3
"""Build an nginx htpasswd file using salted {SSHA} from plaintext per-user
password files.

Run by the `build-htpasswd` init container in services/registry.tf. Reads files
named `password_<user>` from HTPASSWD_SRC_DIR (default /mnt/htpasswd-src),
hashes each value as nginx {SSHA} = base64(sha1(pw + salt) + salt), and writes
`<user>:{SSHA}...` lines to HTPASSWD_OUT_FILE (default /htpasswd/htpasswd).

Why this instead of TF-time hashing: bcrypt() in Terraform re-salts on every
plan (fake drift), which forced `ignore_changes` on the old Vault htpasswd and
silently froze user membership. Hashing at runtime from a deterministic
plaintext source removes that whole failure mode. Stdlib only (hashlib/base64/
os) — deliberately no third-party deps, so the critical registry's startup gains
no PyPI-fetch dependency.
"""
import base64
import hashlib
import os
import pathlib
import sys

PREFIX = "password_"


def ssha(password, salt=None):
    """nginx {SSHA}: base64(sha1(password + salt) + salt). Random salt unless
    one is supplied (tests supply a fixed salt for determinism)."""
    if salt is None:
        salt = os.urandom(8)
    blob = hashlib.sha1(password + salt).digest() + salt
    return "{SSHA}" + base64.b64encode(blob).decode()


def build(src_dir):
    """Return sorted `<user>:{SSHA}...` lines for every non-empty
    password_<user> file in src_dir."""
    lines = []
    for entry in sorted(pathlib.Path(src_dir).iterdir()):
        if not entry.name.startswith(PREFIX) or not entry.is_file():
            continue
        user = entry.name[len(PREFIX):]
        password = entry.read_text().strip().encode()
        if not password:
            continue
        lines.append(f"{user}:{ssha(password)}")
    return lines


def main():
    src_dir = pathlib.Path(os.environ.get("HTPASSWD_SRC_DIR", "/mnt/htpasswd-src"))
    out_file = pathlib.Path(os.environ.get("HTPASSWD_OUT_FILE", "/htpasswd/htpasswd"))
    if not src_dir.is_dir():
        print(f"missing {src_dir}", file=sys.stderr)
        return 1
    lines = build(src_dir)
    if not lines:
        print(
            f"no {PREFIX}<user> entries in {src_dir} — refusing to write empty htpasswd",
            file=sys.stderr,
        )
        return 1
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text("\n".join(lines) + "\n")
    out_file.chmod(0o644)
    print(f"registry-htpasswd: wrote {len(lines)} user(s) -> {out_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
