# Opencode-global skills + pod-wide Rust AGENTS.md.
#
# Per feedback_opencode_target_is_external, opencode's coding target is
# whatever the user clones into the PVC at /home/user/working/<repo>, not
# anything inside this homelab repo. Anything that should reach the
# agent's working tree ships through the opencode pod's filesystem —
# either via a ConfigMap mount or a Dockerfile bake. ConfigMap wins on
# iteration speed (TF apply + Reloader-rolled pod beats image rebuild).
#
# Both the skill bodies and the AGENTS.md live as plain Markdown files
# under data/opencode/ (not inline heredocs) so they're easy to edit and
# diff. The ConfigMaps below read them with file()/fileset():
#   1. opencode-skills      — one key per data/opencode/skills/<name>/SKILL.md,
#                             projected into
#                             /home/user/.config/opencode/skills/<name>/SKILL.md
#                             via the volume `items` mapping in opencode.tf
#                             (which enumerates the SAME fileset). opencode's
#                             skill-discovery glob is
#                             ~/.config/opencode/skills/<name>/SKILL.md.
#   2. opencode-rust-agents — data/opencode/AGENTS.md, mounted read-only into
#                             opencode's global rule slot
#                             (/home/user/.config/opencode/AGENTS.md) so it
#                             always loads regardless of the cloned repo.
#
# Adding a skill = drop data/opencode/skills/<name>/SKILL.md (+ a
# permission.skill allow entry in opencode.json if its name needs one).
# No ConfigMap-key or volume-items edit — both sides are dynamic.

locals {
  # <name>/SKILL.md relative paths, e.g. "rust-review/SKILL.md".
  opencode_skill_files = fileset("${path.module}/../data/opencode/skills", "*/SKILL.md")
  # Skill names = the directory component. Used here for the ConfigMap keys
  # and in services/opencode.tf for the dynamic volume `items` blocks.
  opencode_skill_names = toset([for f in local.opencode_skill_files : dirname(f)])
}

# ─── 1. Skills ──────────────────────────────────────────────────────────────
#
# Frontmatter `name:` in each SKILL.md must match its directory name (opencode
# discovers each at <name>/SKILL.md). `description` is what opencode shows the
# model in the skill-listing tool; keep it short and trigger-y.

resource "kubernetes_config_map" "opencode_skills" {
  metadata {
    name      = "opencode-skills"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  data = {
    for f in local.opencode_skill_files :
    dirname(f) => file("${path.module}/../data/opencode/skills/${f}")
  }
}

# ─── 2. Pod-wide Rust AGENTS.md ─────────────────────────────────────────────
#
# Mounted into opencode's GLOBAL rule slot
# (/home/user/.config/opencode/AGENTS.md) so it ALWAYS loads, even when a
# cloned repo ships its own AGENTS.md (that's the local category and doesn't
# shadow the global one). Body lives at data/opencode/AGENTS.md.

resource "kubernetes_config_map" "opencode_rust_agents" {
  metadata {
    name      = "opencode-rust-agents"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  data = {
    "AGENTS.md" = file("${path.module}/../data/opencode/AGENTS.md")
  }
}
