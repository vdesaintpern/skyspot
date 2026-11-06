terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

# One provider per region. The primary is the CRR source; sec1/sec2 host the
# replicated copies. Keep these regions in sync with your recipes' any_of: lists.
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
