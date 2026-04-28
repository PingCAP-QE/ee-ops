resource "google_artifact_registry_repository" "this" {
  project       = var.project_id
  location      = var.location
  repository_id = var.repository_id
  description   = var.description
  format        = "DOCKER"
  labels        = var.labels
}

resource "google_artifact_registry_repository_iam_member" "delivery_bot_writer" {
  project    = var.project_id
  location   = var.location
  repository = google_artifact_registry_repository.this.name
  role       = "roles/artifactregistry.writer"
  member     = var.delivery_bot_member
}

resource "google_artifact_registry_repository_iam_member" "customer_readers" {
  for_each = toset(var.customer_reader_members)

  project    = var.project_id
  location   = var.location
  repository = google_artifact_registry_repository.this.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}
