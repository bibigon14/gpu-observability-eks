terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
  }

  # Remote state. Reuses the same bootstrap pattern as terraform-eks-platform:
  # one S3 bucket, a per-project state key, DynamoDB lock table.
  # See bootstrap.md. REPLACE_ME values are filled during bootstrap.
  backend "s3" {
    bucket         = "dstepanov-tfstate-493539461415"
    key            = "gpu-observability-eks/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "terraform-eks-platform-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "gpu-observability-eks"
      ManagedBy = "terraform"
    }
  }
}

# Kubernetes + Helm providers authenticate against the cluster created below.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
