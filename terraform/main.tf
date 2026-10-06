data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# --- VPC ----------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1)]
  public_subnets  = [cidrsubnet(var.vpc_cidr, 4, 2), cidrsubnet(var.vpc_cidr, 4, 3)]

  enable_nat_gateway = true
  single_nat_gateway = true # cost optimization for a demo cluster

  # Tags required by EKS for subnet discovery / load balancers.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# --- EKS ----------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Grant the IAM identity that runs `terraform apply` cluster-admin so kubectl works.
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    # Small on-demand CPU pool for the platform: operators, Prometheus, Grafana.
    system = {
      instance_types = ["t3.large"]
      capacity_type  = "ON_DEMAND"
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }

    # GPU pool. EKS GPU-optimized AMI (AL2_x86_64_GPU) ships the NVIDIA driver and
    # container runtime, so the GPU Operator only manages device-plugin / GFD / DCGM.
    gpu = {
      ami_type       = "AL2_x86_64_GPU"
      instance_types = [var.gpu_instance_type]
      capacity_type  = var.gpu_capacity_type

      min_size     = var.gpu_min_size
      max_size     = var.gpu_max_size
      desired_size = var.gpu_desired_size

      # Keep non-GPU pods off the expensive GPU nodes.
      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      labels = {
        "workload-type"                = "gpu"
        "node.kubernetes.io/gpu"       = "true"
        "nvidia.com/gpu.deploy.driver" = "false" # driver comes from the AMI, not the operator
      }
    }
  }
}
