terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
  }
}

variable "bucket_name" {
  description = "Name of the GCS bucket to create. Must be globally unique."
  type        = string
  default = "hello"
}

variable "project" {
  description = "GCP project ID where the bucket will be created."
  type        = string
  default = "pingcap-testing-account"
}

variable "location" {
  description = "The location for the bucket (e.g. US, EU, ASIA)."
  type        = string
  default     = "US"
}

variable "storage_class" {
  description = "The storage class of the bucket (e.g. STANDARD, NEARLINE)."
  type        = string
  default     = "STANDARD"
}

variable "force_destroy" {
  description = "If true, objects will be deleted from the bucket when the bucket is destroyed."
  type        = bool
  default     = false
}

resource "google_storage_bucket" "this" {
  name          = var.bucket_name
  project       = var.project
  location      = var.location
  storage_class = var.storage_class

  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy

  labels = {
    managed_by = "ee-ops"
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

output "bucket_name" {
  description = "Name of the created GCS bucket"
  value       = google_storage_bucket.this.name
}

output "bucket_self_link" {
  description = "Self link for the bucket"
  value       = google_storage_bucket.this.self_link
}

output "bucket_url" {
  description = "gs:// URL for the bucket"
  value       = "gs://${google_storage_bucket.this.name}"
}
