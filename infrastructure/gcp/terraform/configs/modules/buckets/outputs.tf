output "bucket_names" {
  description = "Names of the managed GCS buckets"
  value = {
    hello           = google_storage_bucket.hello.name
    prow-job-cache  = google_storage_bucket.prow_job_cache.name
    # prow-tidb-logs  = google_storage_bucket.prow_tidb_logs.name
  }
}

output "bucket_urls" {
  description = "gs:// URLs for the managed GCS buckets"
  value = {
    hello           = "gs://${google_storage_bucket.hello.name}"
    prow-job-cache  = "gs://${google_storage_bucket.prow_job_cache.name}"
    # prow-tidb-logs  = "gs://${google_storage_bucket.prow_tidb_logs.name}"
  }
}
