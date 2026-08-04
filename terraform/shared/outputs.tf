output "ecr_repository_urls" {
  description = "CI push targets, one per service."
  value       = { for k, r in aws_ecr_repository.svc : k => r.repository_url }
}
