variable "project_id" {
  type        = string
  description = "GCP project id hosting the GAR delivery repository."
}

variable "location" {
  type        = string
  description = "GAR location, for example asia-east1."
}

variable "repository_id" {
  type        = string
  description = "Repository id, usually customer-batch scoped."
}

variable "description" {
  type        = string
  description = "Repository description."
  default     = null
}

variable "labels" {
  type        = map(string)
  description = "Repository labels used for ownership and lifecycle metadata."
  default     = {}
}

variable "delivery_bot_member" {
  type        = string
  description = "IAM member string for the delivery bot writer."
}

variable "customer_reader_members" {
  type        = list(string)
  description = "List of IAM member strings that should have repository reader access."
  default     = []
}
