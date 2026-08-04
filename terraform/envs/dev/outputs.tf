output "cluster_name" {
  description = "Feed to: aws eks update-kubeconfig --name <this>"
  value       = module.stack.cluster_name
}
