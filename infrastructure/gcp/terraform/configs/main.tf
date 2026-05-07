module "buckets" {
  source  = "./modules/buckets"
  project = var.project
}

output "bucket_names" {
  description = "Names of the managed GCS buckets"
  value       = module.buckets.bucket_names
}

output "bucket_urls" {
  description = "gs:// URLs for the managed GCS buckets"
  value       = module.buckets.bucket_urls
}
