#!/usr/bin/env bash
###############################################################################
# IO-107 SDLC Pipeline -- Student dependency installer
#
# Installs every CLI tool a student needs to run Labs 1-4 of IO-107, on a
# dnf-based Amazon Linux 2023 host (the lab EC2, Cloud9, or a personal AL2023
# box). Idempotent -- re-run any time; tools already present at a compatible
# version are skipped.
#
# Tools installed (and which lab needs them):
#   - git, jq, unzip, tar, gcc, python3-pip   base deps (via dnf)
#   - AWS CLI v2                              all labs (clone CodeCommit, drive AWS)
#   - Terraform 1.10.5                        Lab 3 (OPA), Lab 4 (Aurora B/G)
#   - kubectl  1.29.0                         Lab 1 (verify EKS pods/svc/IRSA)
#   - Helm     3.14.4                         Lab 1 (inspect chart / releases)
#   - Conftest 0.50.0                         Lab 3 (run OPA policies locally)
#   - AWS SAM CLI                             Lab 2 (build/test Lambda locally)
#
# Version pins match instructor/install_mgmt_tools.sh and the lab buildspecs,
# so what you run locally matches what CodeBuild runs in the pipeline.
#
# Docker is intentionally NOT installed: the labs build container images inside
# AWS CodeBuild, not on your workstation. Pass --with-docker if you want it for
# the optional Lab 3 "push to ECR" exercise.
#
# Usage:
#   # one-liner straight from the course repo:
#   curl -sSL https://raw.githubusercontent.com/roi-cloud-fun/io-107/main/scripts/install_student_deps.sh | sudo bash
#
#   # or from a local clone:
#   sudo ./scripts/install_student_deps.sh
#   sudo ./scripts/install_student_deps.sh --with-docker
#
# Requires root (uses dnf / writes to /usr/local/bin). The script re-execs
# under sudo if you forget.
###############################################################################

set -euo pipefail

# ----- Version pins (keep in lock-step with instructor/install_mgmt_tools.sh) -----
TERRAFORM_VERSION="1.10.5"     # 1.10+ for native S3 state locking (Lab 3/4 backends)
KUBECTL_VERSION="1.29.0"       # matches the EKS cluster + Lab 1/3 buildspecs
KUBECTL_BUILD_DATE="2024-01-04"
CONFTEST_VERSION="0.50.0"      # matches Lab 3/4 buildspecs
HELM_VERSION="3.14.4"

WITH_DOCKER=0
for arg in "$@"; do
  case "$arg" in
    --with-docker) WITH_DOCKER=1 ;;
    -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ----- Re-exec as root if not already -----
if [ "$EUID" -ne 0 ]; then
  echo "Re-executing under sudo..."
  exec sudo -E bash "$0" "$@"
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  TF_ARCH="amd64"; KUBE_ARCH="amd64"; CFT_ARCH="x86_64"; HELM_ARCH="amd64" ;;
  aarch64) TF_ARCH="arm64"; KUBE_ARCH="arm64"; CFT_ARCH="arm64";  HELM_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "===== IO-107 student deps -- arch: $ARCH ($TF_ARCH), docker: $([ $WITH_DOCKER -eq 1 ] && echo yes || echo no) ====="
echo

# -----------------------------------------------------------------------------
# Base packages via dnf
# -----------------------------------------------------------------------------
echo "===== [1/7] Base packages (git, jq, unzip, tar, gcc, python3-pip) ====="
dnf install -y git jq unzip tar gcc python3-pip
echo

# -----------------------------------------------------------------------------
# AWS CLI v2 -- usually preinstalled on AL2023, install if missing
# -----------------------------------------------------------------------------
echo "===== [2/7] AWS CLI v2 ====="
if command -v aws >/dev/null 2>&1 && aws --version 2>&1 | grep -q "aws-cli/2"; then
  echo "  already installed: $(aws --version)"
else
  cd /tmp
  curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o awscliv2.zip
  unzip -q -o awscliv2.zip
  if [ -e /usr/local/aws-cli ]; then ./aws/install --update; else ./aws/install; fi
  rm -rf aws awscliv2.zip
  echo "  installed: $(aws --version)"
fi
echo

# -----------------------------------------------------------------------------
# Terraform
# -----------------------------------------------------------------------------
echo "===== [3/7] Terraform ${TERRAFORM_VERSION} ====="
if command -v terraform >/dev/null 2>&1 && terraform version | head -1 | grep -q "${TERRAFORM_VERSION}"; then
  echo "  already installed: $(terraform version | head -1)"
else
  cd /tmp
  curl -sSL -o terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TF_ARCH}.zip"
  unzip -q -o terraform.zip -d /usr/local/bin/
  chmod +x /usr/local/bin/terraform
  rm -f terraform.zip
  echo "  installed: $(terraform version | head -1)"
fi
echo

# -----------------------------------------------------------------------------
# kubectl
# -----------------------------------------------------------------------------
echo "===== [4/7] kubectl ${KUBECTL_VERSION} ====="
if command -v kubectl >/dev/null 2>&1 && kubectl version --client=true 2>&1 | grep -q "${KUBECTL_VERSION}"; then
  echo "  already installed: $(kubectl version --client=true 2>&1 | head -1)"
else
  curl -sSL -o /usr/local/bin/kubectl "https://amazon-eks.s3.us-west-2.amazonaws.com/${KUBECTL_VERSION}/${KUBECTL_BUILD_DATE}/bin/linux/${KUBE_ARCH}/kubectl"
  chmod +x /usr/local/bin/kubectl
  echo "  installed: $(kubectl version --client=true 2>&1 | head -1)"
fi
echo

# -----------------------------------------------------------------------------
# Helm
# -----------------------------------------------------------------------------
echo "===== [5/7] Helm ${HELM_VERSION} ====="
if command -v helm >/dev/null 2>&1 && helm version --short | grep -q "${HELM_VERSION}"; then
  echo "  already installed: $(helm version --short)"
else
  cd /tmp
  curl -sSL -o helm.tar.gz "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${HELM_ARCH}.tar.gz"
  tar -xzf helm.tar.gz
  mv "linux-${HELM_ARCH}/helm" /usr/local/bin/helm
  chmod +x /usr/local/bin/helm
  rm -rf helm.tar.gz "linux-${HELM_ARCH}"
  echo "  installed: $(helm version --short)"
fi
echo

# -----------------------------------------------------------------------------
# Conftest (OPA)
# -----------------------------------------------------------------------------
echo "===== [6/7] Conftest ${CONFTEST_VERSION} ====="
if command -v conftest >/dev/null 2>&1 && conftest --version 2>&1 | grep -q "${CONFTEST_VERSION}"; then
  echo "  already installed: $(conftest --version 2>&1 | head -1)"
else
  cd /tmp
  curl -sSL -o conftest.tar.gz "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_${CFT_ARCH}.tar.gz"
  tar -xzf conftest.tar.gz -C /usr/local/bin conftest
  chmod +x /usr/local/bin/conftest
  rm -f conftest.tar.gz
  echo "  installed: $(conftest --version 2>&1 | head -1)"
fi
echo

# -----------------------------------------------------------------------------
# AWS SAM CLI (Lab 2 local build/test)
#
# Use the AWS-provided zip installer rather than pip: on AL2023 the AWS CLI v2
# bundled awscrt (installed via RPM) conflicts with aws-sam-cli's pip awscrt.
# The zip installer is a self-contained PyOxidizer build that sidesteps it.
# -----------------------------------------------------------------------------
echo "===== [7/7] AWS SAM CLI ====="
if command -v sam >/dev/null 2>&1; then
  echo "  already installed: $(sam --version)"
else
  case "$ARCH" in
    x86_64)  SAM_ZIP="aws-sam-cli-linux-x86_64.zip" ;;
    aarch64) SAM_ZIP="aws-sam-cli-linux-arm64.zip" ;;
  esac
  cd /tmp
  curl -sSL -o sam.zip "https://github.com/aws/aws-sam-cli/releases/latest/download/${SAM_ZIP}"
  unzip -q -o sam.zip -d sam-installation
  if [ -e /usr/local/aws-sam-cli ]; then ./sam-installation/install --update; else ./sam-installation/install; fi
  rm -rf sam.zip sam-installation
  echo "  installed: $(sam --version)"
fi
echo

# -----------------------------------------------------------------------------
# Docker (optional -- only for the Lab 3 "push to ECR" bonus)
# -----------------------------------------------------------------------------
if [ $WITH_DOCKER -eq 1 ]; then
  echo "===== [opt] Docker ====="
  if command -v docker >/dev/null 2>&1; then
    echo "  already installed: $(docker --version)"
  else
    dnf install -y docker
    systemctl enable docker
    systemctl start docker
    if id ec2-user >/dev/null 2>&1; then
      usermod -aG docker ec2-user
      echo "  ec2-user added to docker group (log out/in for it to take effect)"
    fi
    echo "  installed: $(docker --version)"
  fi
  echo
fi

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
echo "===== Verification ====="
echo "git:       $(git --version)"
echo "aws:       $(aws --version 2>&1 | head -1)"
echo "terraform: $(terraform version | head -1)"
echo "kubectl:   $(kubectl version --client=true 2>&1 | head -1)"
echo "helm:      $(helm version --short)"
echo "conftest:  $(conftest --version 2>&1 | head -1)"
echo "sam:       $(sam --version 2>/dev/null || echo '(open a new shell to pick up sam)')"
echo "jq:        $(jq --version)"
[ $WITH_DOCKER -eq 1 ] && echo "docker:    $(docker --version)"
echo
echo "===== Done. You're ready to run IO-107 Labs 1-4. ====="
echo "Next: configure your AWS credentials (aws configure, or use the lab role),"
echo "then follow your lab guide's Pre-Lab Setup to clone your CodeCommit repo."
