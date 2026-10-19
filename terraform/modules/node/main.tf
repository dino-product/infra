variable "env" { type = string }
variable "private_ip" { type = string }
variable "subnet_id" { type = string }
variable "vpc_id" { type = string }
variable "instance_type" { default = "t4g.medium" }
variable "volume_gb" { default = 40 }

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

resource "aws_security_group" "node" {
  name        = "orbit-${var.env}-node"
  description = "orbit ${var.env} k3s node"
  vpc_id      = var.vpc_id
  tags        = { Name = "orbit-${var.env}-node" }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "orbit-${var.env}-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name = "orbit-${var.env}-node"
  role = aws_iam_role.node.name
}

resource "aws_instance" "node" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  private_ip             = var.private_ip
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name
  user_data              = file("${path.module}/user_data.sh")

  credit_specification { cpu_credits = "unlimited" }
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # pod에서도 노드 역할
  }
  root_block_device {
    volume_type = "gp3"
    volume_size = var.volume_gb
    encrypted   = true
  }
  lifecycle { ignore_changes = [ami, user_data] }
  tags = { Name = "orbit-${var.env}", Env = var.env, Role = "k3s" }
}

resource "aws_eip" "node" {
  domain   = "vpc"
  instance = aws_instance.node.id
  tags     = { Name = "orbit-${var.env}" }
}

output "instance_id" { value = aws_instance.node.id }
output "sg_id" { value = aws_security_group.node.id }
output "role_name" { value = aws_iam_role.node.name }
output "public_ip" { value = aws_eip.node.public_ip }
