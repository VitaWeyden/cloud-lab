# ── Dynamic "latest known-good version" lookup ─────────────────────────────
#
# The `*_tag` variables in variables.tf are a static fallback, but if the
# Deployments ever get destroyed and recreated from scratch, it'd be nice if
# the very first bootstrap picked up whatever version is actually newest at
# that moment, rather than whatever number was last hardcoded here.
#
# GHCR implements the standard Docker Registry HTTP API v2, which requires a
# short-lived anonymous bearer token even for public images before it'll
# answer a tags/list request - this mirrors exactly what Keel itself does
# internally when polling (see TROUBLESHOOTING.md #10).
#
# This only affects a resource's very first creation. Every application
# Deployment has a `lifecycle { ignore_changes = [...] }` block on its image
# field (see TROUBLESHOOTING.md #15), so once a Deployment exists, Keel owns
# that field completely - these data sources refresh on every plan/apply,
# but that only matters again if the Deployment is ever destroyed and
# recreated.

locals {
  ghcr_images = {
    echoo_backend   = "vitaweyden/echoo-backend"
    echoo_frontend  = "vitaweyden/echoo-frontend"
    violetboard_app = "vitaweyden/violet-board-app"
    violetboard_web = "vitaweyden/violet-board-web"
  }
}

data "http" "ghcr_token" {
  for_each = local.ghcr_images
  url      = "https://ghcr.io/token?service=ghcr.io&scope=repository:${each.value}:pull"
}

data "http" "ghcr_tags" {
  for_each = local.ghcr_images
  url      = "https://ghcr.io/v2/${each.value}/tags/list"
  request_headers = {
    Authorization = "Bearer ${jsondecode(data.http.ghcr_token[each.key].response_body).token}"
  }
}

locals {
  # Tags this project's CI produces are always "v0.0.<N>" (see each app's
  # .github/workflows/docker.yml) - major and minor are always 0, so it's
  # enough to pull out just the patch number and take the highest one.
  # Anything that doesn't match this exact shape (e.g. "latest") is ignored.
  ghcr_patch_numbers = {
    for key, image in local.ghcr_images : key => [
      for t in try(jsondecode(data.http.ghcr_tags[key].response_body).tags, []) :
      tonumber(regex("^v0\\.0\\.(\\d+)$", t)[0])
      if can(regex("^v0\\.0\\.(\\d+)$", t))
    ]
  }

  # Falls back to the corresponding variable default if the lookup fails or
  # the registry has no matching tags yet (e.g. before the first CI run with
  # the versioned-tag workflow has happened at all).
  echoo_backend_latest_tag   = length(local.ghcr_patch_numbers["echoo_backend"]) > 0 ? "v0.0.${max(local.ghcr_patch_numbers["echoo_backend"]...)}" : var.echoo_backend_tag
  echoo_frontend_latest_tag  = length(local.ghcr_patch_numbers["echoo_frontend"]) > 0 ? "v0.0.${max(local.ghcr_patch_numbers["echoo_frontend"]...)}" : var.echoo_frontend_tag
  violetboard_app_latest_tag = length(local.ghcr_patch_numbers["violetboard_app"]) > 0 ? "v0.0.${max(local.ghcr_patch_numbers["violetboard_app"]...)}" : var.violetboard_app_tag
  violetboard_web_latest_tag = length(local.ghcr_patch_numbers["violetboard_web"]) > 0 ? "v0.0.${max(local.ghcr_patch_numbers["violetboard_web"]...)}" : var.violetboard_web_tag
}