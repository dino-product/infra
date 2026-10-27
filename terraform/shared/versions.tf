terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.51"
    }
  }
  backend "s3" {
    bucket       = "orbit-tfstate-714047901967"
    key          = "shared/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "ap-northeast-2"
  default_tags { tags = { Project = "orbit", ManagedBy = "terraform", Repo = "dino-product/infra" } }
}

# ACM 인증서 Cloudfront용 -> 꼭 us-east-1
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
  default_tags { tags = { Project = "orbit", ManagedBy = "terraform" } }
}