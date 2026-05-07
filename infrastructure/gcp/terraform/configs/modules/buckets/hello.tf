resource "google_storage_bucket" "hello" {
  name                        = "hello-pingcap-testing-account"
  project                     = var.project
  location                    = "US"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true
  public_access_prevention    = "inherited"

  labels = {
    managed_by  = "ee-ops"
    environment = "gcp"
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 365
    }
  }
}
