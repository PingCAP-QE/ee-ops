# One-time import blocks for existing GCS buckets.
# These tell Terraform to import existing buckets into state instead of
# trying to create them (which would fail with 409 conflict).
#
# After the first successful apply, remove this file and push again.
# The import blocks are safe to keep — once a resource is in state,
# Terraform ignores its import block on subsequent runs.

import {
  to = module.buckets.google_storage_bucket.prow_job_cache
  id = "prow-job-cache"
}
