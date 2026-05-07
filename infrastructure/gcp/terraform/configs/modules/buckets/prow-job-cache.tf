resource "google_storage_bucket" "prow_job_cache" {
  name                        = "prow-job-cache"
  project                     = var.project
  location                    = "US-CENTRAL1"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false
  public_access_prevention    = "enforced"

  labels = {
    managed_by  = "ee-ops"
    environment = "gcp"
  }
}
