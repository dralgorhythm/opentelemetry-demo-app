# VPC endpoints. Without one, every S3 call from a node/pod — including every
# ECR image-layer pull, which is S3 under the hood — transits the NAT gateway:
# $0.045/GB data processing on top of the flat NAT hourly fee. A Gateway
# endpoint for S3 is FREE (no hourly charge, no per-GB charge) and routes that
# traffic on AWS's internal network instead — pure cost + resilience win, zero
# app change (same DNS name, same SDK calls; only the route table changes).
#
# DECISION: Gateway-only (active) vs also adding interface endpoints for
# ECR/STS/Secrets Manager (~$0.01/hr/AZ each, ~$22/mo per service across 3
# AZs). Interface endpoints earn their keep once image-pull volume or NAT
# data volume grows, or once the API endpoint goes private — a private
# cluster with no interface endpoints can't pull images or read secrets at
# all. Skipped for now: this demo's NAT bill is already tiny (single NAT,
# low traffic), so the per-AZ hourly cost isn't yet justified.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
}
