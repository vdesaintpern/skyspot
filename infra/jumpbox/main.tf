# SkySpot jumpbox - the SkyPilot CONTROL HOST (and inference-test tunnel).
#
# A small box in a PRIVATE subnet of the SkySpot VPC, reached from your laptop
# over SSM Session Manager (no inbound SSH, no public IP). You run the `sky` CLI
# HERE, not on your laptop: because the jumpbox is inside the VPC, SkyPilot talks
# to the controller and workers over DIRECT private-IP SSH (use_ssm: false),
# which is the configuration proven to work. (SSM from an in-VPC client to the
# workers does NOT work - that is exactly why sky runs here, not on your laptop.)
#
#   laptop  --SSM-->  jumpbox (runs sky)  --private-IP SSH-->  controller / workers
#   laptop  --SSM-->  jumpbox  --VPC-->  vLLM server :8000   (inference testing)
#
# sky is pre-installed and configured by user-data (see bootstrap.sh.tftpl).

# Find the SkySpot VPC and one private subnet by tag.
data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  filter {
    name   = "tag:Tier"
    values = ["private-workload"]
  }
}

# Latest Amazon Linux 2023 AMI (ships the SSM agent).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# IAM role so the instance registers as an SSM managed node.
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jumpbox" {
  name_prefix        = "${var.name}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jumpbox.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The jumpbox runs the sky CLI, so its role needs SkyPilot's AWS permissions:
# launch/terminate EC2, read/write S3 for data+weights, and manage/pass the
# skypilot-v1 instance role that workers run as.
resource "aws_iam_role_policy_attachment" "ec2" {
  role       = aws_iam_role.jumpbox.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

resource "aws_iam_role_policy_attachment" "s3" {
  role       = aws_iam_role.jumpbox.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# IAM actions SkyPilot needs to create (first run) and pass the skypilot-v1 role.
# Scoped to skypilot-v1; broaden only if a fresh account needs it (see SkyPilot's
# AWS IAM docs). The read actions must be * (list/get across IAM).
resource "aws_iam_role_policy" "skypilot_iam" {
  name_prefix = "skypilot-iam-"
  role        = aws_iam_role.jumpbox.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageAndPassSkyPilotRole"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:GetInstanceProfile", "iam:CreateRole",
          "iam:CreateInstanceProfile", "iam:AddRoleToInstanceProfile",
          "iam:AttachRolePolicy", "iam:PutRolePolicy", "iam:TagRole",
          "iam:TagInstanceProfile", "iam:PassRole"
        ]
        Resource = [
          "arn:aws:iam::*:role/skypilot-v1",
          "arn:aws:iam::*:instance-profile/skypilot-v1"
        ]
      },
      {
        Sid      = "SkyPilotIamRead"
        Effect   = "Allow"
        Action   = ["iam:ListRoles", "iam:ListInstanceProfiles", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "jumpbox" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.jumpbox.name
}

# Egress-only SG: SSM is agent-initiated outbound; nothing needs to reach the box.
resource "aws_security_group" "jumpbox" {
  name_prefix = "${var.name}-"
  description = "SkySpot jumpbox - egress only, SSM managed"
  vpc_id      = data.aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_instance" "jumpbox" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.private.ids[0]
  iam_instance_profile   = aws_iam_instance_profile.jumpbox.name
  vpc_security_group_ids = [aws_security_group.jumpbox.id]
  # No public IP - reached only via SSM.
  associate_public_ip_address = false

  # Install + configure SkyPilot (direct-SSH, no SSM) on first boot.
  user_data = templatefile("${path.module}/bootstrap.sh.tftpl", {
    vpc_name = var.vpc_name
    region   = var.region
  })
  # Replace the instance if the bootstrap changes.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 30
  }

  tags = merge(var.tags, { Name = var.name })
}
