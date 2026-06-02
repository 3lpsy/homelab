---
name: commit-conventional
description: Write a Conventional Commits message for the current staged diff. Subject ≤50 chars, body only when "why" isn't obvious.
---
# commit-conventional

Mirrors the caveman-commit pattern but runs inside opencode so the
remote agent doesn't depend on a Claude-Code plugin.

Process:

1. Read the staged diff: `git diff --staged`.
2. Pick the right type:
   - `feat:`     new user-visible behavior
   - `fix:`      bug fix
   - `refactor:` no behavior change
   - `docs:`     docs only
   - `test:`     test-only changes
   - `chore:`    deps, build, tooling
   - `perf:`     perf without behavior change
3. Subject: imperative mood, ≤50 chars, no trailing period.
   Form: `<type>(<scope>): <subject>` — scope optional.
4. Body: include ONLY if the "why" isn't obvious from the diff.
   Wrap at 72. No "this commit does X" filler.
5. Output the message and nothing else — no preamble like "Here's
   your commit:".

Do not actually run `git commit` — return the message text only;
the user pipes it.
