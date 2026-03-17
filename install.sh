#!/bin/bash
exec > /var/log/ami-install.log 2>&1
set -ex

# SSM Agent
snap install amazon-ssm-agent --classic || true
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service || true
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service || true
sleep 30

echo "=============================="
echo " Starting AMI dependency install"
echo "=============================="

# 1. SYSTEM UPDATE
for i in 1 2 3; do
  apt-get update -y && break
  sleep 10
done

# ── 2. CORE PACKAGES ──────────────────────────────────────────────────────────
apt-get install -y \
  curl unzip git tar jq \
  libicu-dev \
  python3 python3-pip \
  docker.io \
  ca-certificates \
  gnupg \
  software-properties-common

# ── 3. NODE.JS 20 LTS (via NodeSource — avoids old apt version) ───────────────
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Verify
node --version
npm --version

# ── 4. AWS CLI ─────────────────────────────────────────────────────────────────
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip
aws --version

# ── 5. TERRAFORM ───────────────────────────────────────────────────────────────
TERRAFORM_VERSION="1.10.5"
curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip
unzip -q /tmp/terraform.zip -d /usr/local/bin/
chmod +x /usr/local/bin/terraform
rm /tmp/terraform.zip
terraform version

# ── 6. TFLINT ──────────────────────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
tflint --version

# ── 7. CHECKOV ─────────────────────────────────────────────────────────────────
pip3 install checkov --upgrade --break-system-packages
checkov --version

# ── 8. DOCKER ──────────────────────────────────────────────────────────────────
systemctl enable docker
systemctl start docker
docker --version

# ── 9. UBUNTU USER SETUP ───────────────────────────────────────────────────────
# Create ubuntu user if it doesn't exist (some AMIs use ec2-user)
if ! id "ubuntu" &>/dev/null; then
  useradd -m -s /bin/bash ubuntu
fi
usermod -aG docker ubuntu
usermod -aG sudo ubuntu

# Allow ubuntu to sudo without password (needed for runner)
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu
chmod 440 /etc/sudoers.d/ubuntu

# ── 10. RUNNER DIRECTORY ───────────────────────────────────────────────────────
mkdir -p /home/ubuntu/actions-runner
chown -R ubuntu:ubuntu /home/ubuntu/actions-runner

echo "=============================="
echo " AMI install complete!"
echo "=============================="
