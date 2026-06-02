---
name: skill-creator
description: Author or refine an opencode skill for the repo you're working in. Use when the user wants to capture a repeatable workflow as a reusable SKILL.md committed to the project.
---
# skill-creator

Create a skill for the **current working repo** — a reusable, triggerable
instruction set committed alongside the code, so the next session (or a
teammate's opencode) picks up the workflow automatically.

## Where the file goes

Per-repo skills live in the repo you're editing, NOT anywhere global:

    <repo-root>/.opencode/skills/<name>/SKILL.md

`<name>` is kebab-case and must match the `name:` in the frontmatter.
opencode discovers it on the next session in that repo. Commit it like
any other source file so it travels with the project.

## SKILL.md shape

    ---
    name: <kebab-case-name>
    description: <one line — what it does AND when to reach for it>
    ---
    # <name>

    <body: the workflow, the commands, the guardrails>

Frontmatter `name` + `description` are required. The `description` is the
ONLY thing the model sees when deciding whether to trigger the skill, so
make it specific and trigger-y. Bad: "Helps with tests." Good: "Run the
project's integration suite against a throwaway podman Postgres and parse
failures."

## Workflow

1. **Capture intent.** What workflow should this skill encode? Which user
   phrases should trigger it? What's the expected output? Pull from the
   conversation first; ask the user only for the gaps.
2. **Ground it in THIS repo.** A good per-repo skill names the repo's real
   commands, paths, and conventions (the test runner it actually uses, the
   `just`/`make` targets that exist, the lint config). Read the repo before
   writing — don't emit generic advice the project doesn't follow.
3. **Draft** the SKILL.md at `.opencode/skills/<name>/SKILL.md`.
4. **Test triggering.** Confirm a prompt that should hit it does, and one
   that shouldn't doesn't. Refine the `description` until the boundary is
   right.
5. **Commit** it with a clear message so it ships with the repo.

## Principles

- **Explain WHY, not just rules.** A model follows reasoned guidance and
  generalizes better than it follows a bare list of MUSTs.
- **Progressive disclosure.** The `description` loads always; the body
  only on trigger. Keep the body tight (well under ~500 lines) so
  triggering stays cheap.
- **Don't overfit.** When a test prompt misfires, ask whether the fix
  helps the general case or only that one example.
- **One skill, one job.** If it's branching into several unrelated
  workflows, split it into separate skills with sharper descriptions.
