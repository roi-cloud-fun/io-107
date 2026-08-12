###############################################################################
# IO-107 -- student management workstations
#
# One EC2 box per student, pre-loaded with the lab toolchain, so class does not
# start with 8 people clicking through the EC2 launch wizard.
#
# This is a SEPARATE module with its OWN state on purpose. The lab environments
# in lab_environment/lab_env_student/ are deployed, verified and must not be
# re-applied to add workstations -- a mistake there costs a student their whole
# environment. Nothing here reads or writes that state.
#
# Apply once per region (the cohort is split), each with its own backend key.
###############################################################################

# Always the current Amazon Linux 2023 AMI for this region -- no hardcoded
# ami-* that silently rots between cohorts.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Workstations live in the DEFAULT VPC, deliberately. They only need outbound
# internet (to install tools and reach AWS APIs) and they must not depend on
# any student's lab VPC -- that would couple this state to theirs.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Inbound SSH is restricted to the EC2 Instance Connect service ranges for this
# region. Students already hold the EC2InstanceConnect managed policy, so
# Console -> Connect works with no key pair, no shared secret, and no 0.0.0.0/0.
data "aws_ip_ranges" "eic" {
  regions  = [var.aws_region]
  services = ["ec2_instance_connect"]
}

resource "aws_security_group" "workstation" {
  name        = "${var.name_prefix}-workstation"
  description = "IO-107 student workstation: egress all, SSH only from EC2 Instance Connect"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.name_prefix}-workstation" }
}

resource "aws_vpc_security_group_ingress_rule" "eic_ssh" {
  for_each = toset(data.aws_ip_ranges.eic.cidr_blocks)

  security_group_id = aws_security_group.workstation.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "EC2 Instance Connect"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.workstation.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound: package repos, GitHub, AWS APIs"
}

resource "aws_instance" "workstation" {
  for_each = toset(var.students)

  ami                  = data.aws_ssm_parameter.al2023.value
  instance_type        = var.instance_type
  subnet_id            = element(sort(data.aws_subnets.default.ids), index(sort(var.students), each.key) % length(data.aws_subnets.default.ids))
  iam_instance_profile = var.instance_profile

  vpc_security_group_ids      = [aws_security_group.workstation.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    student_id = each.key
    repo_url   = var.monorepo_url
  })

  # Toolchain versions are pinned inside install_student_deps.sh, so a change
  # there should rebuild the box rather than silently leave old tools behind.
  user_data_replace_on_change = true

  tags = {
    Name      = "${var.name_prefix}-${each.key}-workstation"
    Student   = each.key
    ManagedBy = "terraform"
    Purpose   = "io107-student-workstation"
  }
}
