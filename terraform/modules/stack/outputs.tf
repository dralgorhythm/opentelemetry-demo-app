output "cluster_name" {
  description = "Feed to: aws eks update-kubeconfig --name <this>"
  value       = module.eks.cluster_name
}

output "redis_primary_endpoint" {
  description = "ElastiCache primary endpoint (writes go here; already baked into the app-config secret)."
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "redis_secret_arn" {
  description = "Secrets Manager secret holding the app's whole config.yml (rediss URL + listen address)."
  value       = aws_secretsmanager_secret.app_config.arn
}
