terraform {
  required_version = ">= 1.10"

  # State in the bootstrap bucket; scripts/datadog.sh supplies the backend settings.
  backend "s3" {}

  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 4.27"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
  }
}
