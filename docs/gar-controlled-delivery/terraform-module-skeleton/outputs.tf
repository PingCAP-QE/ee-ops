output "repository_name" {
  value       = google_artifact_registry_repository.this.name
  description = "Fully qualified GAR repository resource name."
}

output "repository_id" {
  value       = google_artifact_registry_repository.this.repository_id
  description = "GAR repository id."
}
