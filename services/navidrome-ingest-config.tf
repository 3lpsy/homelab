# Prompt + JSON schema mounted at /etc/ingest/. Watched by Reloader so
# tweaking the prompt rolls the worker without rebuilding the image.
#
# The prompt is read from data/navidrome-ingest/prompt.j2 if present
# (gitignored — for personal corpus customization without leaking
# artist names / listening habits to the repo) and falls back to
# prompt.example.j2 (committed, generic) otherwise. Copy the example
# file to prompt.j2 and edit there to customize.
locals {
  navidrome_ingest_prompt_path = (
    fileexists("${path.module}/../data/navidrome-ingest/prompt.j2")
    ? "${path.module}/../data/navidrome-ingest/prompt.j2"
    : "${path.module}/../data/navidrome-ingest/prompt.example.j2"
  )
}

resource "kubernetes_config_map" "navidrome_ingest_prompt" {
  metadata {
    name      = "navidrome-ingest-prompt"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }
  data = {
    "prompt.j2" = file(local.navidrome_ingest_prompt_path)
    "schema.json" = jsonencode({
      "type"     = "object"
      "required" = ["artist", "title", "confidence"]
      "properties" = {
        "artist"     = { "type" = ["string", "null"], "description" = "Primary artist or `A x B` for collabs. Null when no clear artist in the filename." }
        "title"      = { "type" = "string", "description" = "Song title, without quality/attribution suffixes." }
        "album"      = { "type" = ["string", "null"], "description" = "Album name if obvious from filename — otherwise null." }
        "genre"      = { "type" = ["string", "null"], "description" = "Best-guess genre (Hardstyle, Phonk, Hip-Hop, etc.)." }
        "year"       = { "type" = ["string", "null"], "description" = "4-digit year if discernible, else null." }
        "confidence" = { "type" = "number", "minimum" = 0, "maximum" = 1, "description" = "How sure you are that artist+title are correct." }
      }
    })
  }
}
