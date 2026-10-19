data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = "orbit-tfstate-714047901967"
    key    = "shared/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
locals { shared = data.terraform_remote_state.shared.outputs }