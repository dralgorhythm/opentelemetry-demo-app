# Standard three-tier VPC. The module's real value is the route-table wiring and
# subnet arithmetic; conceptually it's public subnets (ALB, NAT) + private subnets
# (nodes, pods) across AZs, with the discovery tags EKS needs to place LBs.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = var.vpc_cidr

  azs = slice(data.aws_availability_zones.available.names, 0, 3)
  # /19 (8k IPs) per private subnet on purpose: the VPC CNI gives every pod a
  # REAL VPC IP, so small subnets cap pod count (the classic gotcha).
  # Derived from the env's /16 — for 10.0.0.0/16 this is 10.0.0.0/19,
  # 10.0.32.0/19, 10.0.64.0/19 + 10.0.96-98.0/24.
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 3, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, 96 + i)]

  enable_nat_gateway = true

  # DECISION: NAT topology — single (active) vs one-per-AZ.
  # Single NAT is the big cost saver (~$32/mo + data) but a single egress SPOF.
  # For real HA, an env root passes single_nat_gateway = false (the module
  # then creates one NAT per AZ).
  single_nat_gateway = var.single_nat_gateway # cost over HA by default

  # Subnet discovery tags: the cluster reads these to know where to put ELBs.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}
