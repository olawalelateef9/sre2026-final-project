terraform {
  required_version = ">= 1.10"

  # Partial configuration: scripts/up.sh supplies bucket, key, region and use_lockfile
  # from the bootstrap stack's outputs.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "techbleat-global-bank"
      Stack     = "cluster"
      ManagedBy = "terraform"
    }
  }
}
