#!/usr/bin/env bash
###############################################################################
# IO-107 -- Management EC2 toolchain installer
#
# Idempotent install of every CLI tool the instructor (or smoke-test driver)
# needs on the management EC2 host to drive Lab 1-4 end-to-end. Re-run any
# time -- skips tools that are already installed at a compatible version.
#
# Tested on Amazon Linux 2023. Should work on AL2 with minor differences in
# package names.
#
# Tools installed:
#   - jq, unzip, git, tar           (via dnf -- usually preinstalled on AL2023)
#   - AWS CLI v2                    (latest, from awscli.amazonaws.com)
#   - Terraform                     (HashiCorp zip release, pinned)
#   - kubectl                       (Amazon EKS-matched build, pinned)
#   - Helm                          (CNCF script from get.helm.sh)
#   - Conftest                      (OPA project, pinned)
#   - SAM CLI                       (via pip3)
#   - Docker                        (for Lab 3 bonus: docker pull/tag/push to ECR)
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/roi-cloud-fun/io-107/main/instructor/install_mgmt_tools.sh | sudo bash
#
#   OR:
#   git clone https://github.com/roi-cloud-fun/io-107.git
#   sudo ./io-107/instructor/install_mgmt_tools.sh
#
# Requires root (uses sudo for dnf / writes to /usr/local/bin). The script
# checks for root and re-execs under sudo if needed.
###############################################################################

set -euo pipefail

# ----- Version pins (match lab buildspecs / Course CLAUDE.md) -----
TERRAFORM_VERSION="1.10.5"     # 1.10+ for native S3 locking (Lab 3/4 backends)
KUBECTL_VERSION="1.29.0"       # matches Lab 3 buildspec
KUBECTL_BUILD_DATE="2024-01-04"
CONFTEST_VERSION="0.50.0"      # matches Lab 4 buildspec
HELM_VERSION="3.14.4"

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

echo "===== Detected arch: $ARCH ($TF_ARCH) ====="
echo

# -----------------------------------------------------------------------------
# Base packages via dnf
# -----------------------------------------------------------------------------
echo "===== [1/9] Base packages (jq, unzip, git, tar, gcc, python3-pip) ====="
dnf install -y jq unzip git tar gcc python3-pip
echo

# -----------------------------------------------------------------------------
# AWS CLI v2
# -----------------------------------------------------------------------------
echo "===== [2/9] AWS CLI v2 ====="
if command -v aws >/dev/null 2>&1 && aws --version 2>&1 | grep -q "aws-cli/2"; then
  echo "  already installed: $(aws --version)"
else
  cd /tmp
  curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o awscliv2.zip
  unzip -q -o awscliv2.zip
  ./aws/install --update
  rm -rf aws awscliv2.zip
  echo "  installed: $(aws --version)"
fi
echo

# -----------------------------------------------------------------------------
# Terraform
# -----------------------------------------------------------------------------
echo "===== [3/9] Terraform ${TERRAFORM_VERSION} ====="
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
echo "===== [4/9] kubectl ${KUBECTL_VERSION} ====="
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
echo "===== [5/9] Helm ${HELM_VERSION} ====="
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
echo "===== [6/9] Conftest ${CONFTEST_VERSION} ====="
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
# SAM CLI (for Lab 2 local testing)
#
# Use the AWS-provided zip installer rather than pip. On Amazon Linux 2023
# the AWS CLI v2 bundled installer drops awscrt via RPM, and aws-sam-cli's
# pip-installed awscrt conflicts: "Cannot uninstall awscrt: RECORD file not
# found. The package was installed by rpm." The zip installer is a
# self-contained PyOxidizer build that avoids the system Python entirely.
# -----------------------------------------------------------------------------
echo "===== [7/9] AWS SAM CLI ====="
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
  # Installer is idempotent on re-run via --update; fresh install otherwise.
  if [ -e /usr/local/aws-sam-cli ]; then
    ./sam-installation/install --update
  else
    ./sam-installation/install
  fi
  rm -rf sam.zip sam-installation
  echo "  installed: $(sam --version)"
fi
echo

# -----------------------------------------------------------------------------
# Docker (for Lab 3 bonus: ECR push)
# -----------------------------------------------------------------------------
echo "===== [8/9] Docker ====="
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

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
echo "===== [9/9] Verification ====="
echo "aws:       $(aws --version 2>&1 | head -1)"
echo "terraform: $(terraform version | head -1)"
echo "kubectl:   $(kubectl version --client=true 2>&1 | head -1)"
echo "helm:      $(helm version --short)"
echo "conftest:  $(conftest --version 2>&1 | head -1)"
echo "sam:       $(sam --version 2>/dev/null || echo '(open new shell to pick up sam)')"
echo "docker:    $(docker --version)"
echo "jq:        $(jq --version)"
echo "git:       $(git --version)"
echo
echo "===== Done. Management EC2 ready for IO-107 lab delivery. ====="
