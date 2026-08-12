# Student management workstations

One EC2 box per student, pre-loaded with the lab toolchain, so class does not
open with eight people clicking through the EC2 launch wizard.

`STUDENT_SETUP.md` Steps 1–4 (launch an instance, connect, install tools, clone
the repo) exist for students who build their own box. When you deploy these,
those steps are already done — hand each student their instance and they start
at Step 5.

## Why this is a separate module

The lab environments in `lab_environment/lab_env_student/` are deployed and
verified. Adding workstations there would mean re-applying all of them, and a
mistake in that state costs a student their entire environment. This module has
its **own state** and reads nothing from theirs, so the worst case here is a
broken workstation.

## What it builds, per region

- `t3.medium`, latest Amazon Linux 2023 (resolved from SSM — no rotting `ami-*`)
- 30 GiB encrypted gp3 root (the 8 GiB default fills up during Lab 3's Docker work)
- Instance profile `Terraform-InstanceRole` — the same one `STUDENT_SETUP.md`
  tells students to attach by hand
- IMDSv2 required
- One security group: egress anywhere, inbound SSH **only** from this region's
  EC2 Instance Connect ranges (fetched via `aws_ip_ranges`, never `0.0.0.0/0`)
- Placed in the **default VPC**, deliberately — workstations need outbound
  internet and nothing else, and must not couple to any student's lab VPC

`user_data` installs the toolchain via `scripts/install_student_deps.sh`
(the same pinned versions the buildspecs use), pre-clones the course repo to
`~/io-107`, configures git for CodeCommit, and writes a MOTD with the student's
own id and the never-run-`terraform apply` warning.

## Access

**EC2 Instance Connect**, no key pairs: Console → EC2 → Instances → *their*
instance → Connect → EC2 Instance Connect, user `ec2-user`. Students already
hold the `EC2InstanceConnect` managed policy, so this needs no IAM change.

SSM Session Manager would be nicer but `Terraform-InstanceRole` carries only
`TerraformPowerUser` (no `AmazonSSMManagedInstanceCore`), and students' group
does not grant `ssm:StartSession` — both would have to change first.

## Use

Drive it through `instructor/cohort/deploy_workstations.sh`, which applies it
once per region with the right student list and its own state key:

```bash
../cohort/deploy_workstations.sh plan
../cohort/deploy_workstations.sh apply
../cohort/deploy_workstations.sh destroy          # end of course
```

Then park them between sessions — they bill while running:

```bash
../cohort/power.sh stop
```

## Capacity

Each workstation is 2 vCPU against the EC2 "Running On-Demand Standard" quota,
on top of 4 vCPU per student for their EKS nodes. Four students plus four
workstations is 24 vCPU per region. Check headroom before adding students:
`power.sh status` and the quota (`ec2` / `L-1216C47A`).

## Verifying a box came up

`user_data` logs to `/var/log/io107-setup.log` and touches
`/var/lib/io107-setup-complete` when finished. From outside the box:

```bash
aws ec2 get-console-output --region <region> --instance-id <id> \
  --query Output --output text | grep 'IO-107 workstation setup'
```
