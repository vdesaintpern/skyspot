terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

# Primary + two secondaries. Must match the regions your recipes' any_of: lists use
# and where you deployed a skyspot-vpc (infra/vpc).
provider "aws" {
  region = var.primary_region
}

provider "aws" {
  alias  = "sec1"
  region = var.secondary_region_1
}

provider "aws" {
  alias  = "sec2"
  region = var.secondary_region_2
}
