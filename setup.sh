#!/bin/bash
# Bash script to configure a Hostinger VPS for Ansible DevOps deployments and GitHub Actions
# Run as root user via SSH
# Target: Ubuntu 22.04/24.04 VPS
# Prepares VPS for Bitcoin Cash Node (Chipnet/Mainnet) with secrets managed via GitHub Secrets
# Added Fulcrum installation for Electrum server support
#
# Responsibilities of this script (bootstrap):
#  - Detect VPS public IPv4 for GitHub Secrets
#  - Install base packages + Ansible
#  - Install BCHN binaries
#  - Install Fulcrum binaries (+ FulcrumAdmin)
#  - Create deploy user and SSH access
#  - Harden SSH
#  - Configure firewall (UFW) + fail2ban
#  - Output values needed for GitHub Actions Secrets
#
# Non-responsibilities (handled by Ansible in this repo):
#  - Writing bitcoin.conf / systemd unit files for mainnet + chipnet
#  - Writing fulcrum.conf / systemd unit files for mainnet + chipnet
#  - Managing TLS certificates and Fulcrum cert/key paths
#  - Enabling and starting BCHN/Fulcrum services

set -e

# -----------------------------
# Variables
# -----------------------------
DEPLOY_USER="deployer" # Matches VAULT_DEPLOY_USER
DEPLOY_HOME="/home/$DEPLOY_USER"
SSH_PORT="22"

FULCRUM_USER="fulcrum"
FULCRUM_HOME="/home/$FULCRUM_USER"

# Pin versions (bootstrap installs binaries only; Ansible configures services)
FULCRUM_VERSION="1.12.0"
BCHN_VERSION="28.0.0"

# Firewall ports (match repo conventions)
# BCHN:
BCHN_CHIPNET_P2P_PORT="48333"
# Fulcrum ports (Chipnet defaults in this repo)
# 50001 = TCP, 50002 = SSL, 50004 = WSS
FULCRUM_PORT_SSL="50002"
FULCRUM_PORT_TCP="50001"
FULCRUM_PORT_WSS="50004"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

print_message() { echo -e "${GREEN}[INFO] $1${NC}"; }
print_error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# -----------------------------
# Safety checks
# -----------------------------
[ "$(id -u)" -ne 0 ] && print_error "This script must be run as root"

# -----------------------------
# Robust IPv4 detection (for VAULT_SERVER_IP)
# -----------------------------
print_message "Obtaining SERVER_IP..."
SERVER_IP=""
for method in \
  "curl -s ifconfig.me" \
  "curl -s https://api.ipify.org" \
  "ip route get 1.1.1.1 | awk '{print \$7}' | head -1" \
  "hostname -I | awk '{print \$1}'"; do
  SERVER_IP=$(bash -c "$method" 2>/dev/null || true)
  if [[ -n "$SERVER_IP" && "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print_message "Detected SERVER_IP: $SERVER_IP"
    break
  fi
done
[ -z "$SERVER_IP" ] && print_error "Failed to obtain SERVER_IP"

# -----------------------------
# Update system packages
# -----------------------------
print_message "Updating system packages..."
apt update && apt upgrade -y

# -----------------------------
# Install essential packages (including acl for Ansible become_user ACL support)
# -----------------------------
print_message "Installing essential packages..."
apt install -y \
  python3 python3-pip \
  git curl wget unzip \
  software-properties-common apt-transport-https ca-certificates gnupg lsb-release \
  openssl gpg \
  acl \
  ufw \
  fail2ban

# -----------------------------
# Install Ansible
# -----------------------------
print_message "Installing Ansible..."
apt install -y ansible
ansible --version >/dev/null 2>&1 || print_error "Ansible installation failed"

# -----------------------------
# Install Bitcoin Cash Node binary (installs to /usr/local/bin)
# -----------------------------
if [ -f /usr/local/bin/bitcoind ]; then
  print_message "Bitcoin Cash Node already installed at /usr/local/bin/bitcoind, skipping installation"
else
  print_message "Installing Bitcoin Cash Node v$BCHN_VERSION..."
  cd /tmp
  rm -rf "bitcoin-cash-node-${BCHN_VERSION}"* SHA256SUMS || true

  wget -q "https://github.com/bitcoin-cash-node/bitcoin-cash-node/releases/download/v${BCHN_VERSION}/bitcoin-cash-node-${BCHN_VERSION}-x86_64-linux-gnu.tar.gz"
  wget -q "https://github.com/bitcoin-cash-node/bitcoin-cash-node/releases/download/v${BCHN_VERSION}/SHA256SUMS"

  grep 'x86_64-linux-gnu.tar.gz' SHA256SUMS | sha256sum --check || print_error "SHA256 checksum failed"
  tar -xzf "bitcoin-cash-node-${BCHN_VERSION}-x86_64-linux-gnu.tar.gz"

  install -m 0755 -o root -g root -t /usr/local/bin "bitcoin-cash-node-${BCHN_VERSION}/bin/"*
  /usr/local/bin/bitcoind --version >/dev/null 2>&1 || print_error "Bitcoin Cash Node installation failed"
  print_message "Bitcoin Cash Node installed successfully to /usr/local/bin"
fi

# -----------------------------
# Install Fulcrum (Fulcrum + FulcrumAdmin) with signature verification
# -----------------------------
if [ -f /usr/local/bin/Fulcrum ]; then
  print_message "Fulcrum already installed at /usr/local/bin/Fulcrum, skipping installation"
else
  print_message "Installing Fulcrum Electrum server v$FULCRUM_VERSION..."

  # Create fulcrum user
  if ! id "$FULCRUM_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$FULCRUM_USER"
    print_message "User $FULCRUM_USER created successfully"
  else
    print_message "User $FULCRUM_USER already exists"
  fi

  # Download & verify as fulcrum user (mirrors original behavior)
  su - "$FULCRUM_USER" -c "
    set -e
    cd ~
    rm -rf Fulcrum-${FULCRUM_VERSION}-x86_64-linux Fulcrum-${FULCRUM_VERSION}-x86_64-linux.tar.gz* Fulcrum-${FULCRUM_VERSION}-shasums.txt* calinkey.txt || true

    wget -q https://github.com/cculianu/Fulcrum/releases/download/v${FULCRUM_VERSION}/Fulcrum-${FULCRUM_VERSION}-x86_64-linux.tar.gz
    wget -q https://github.com/cculianu/Fulcrum/releases/download/v${FULCRUM_VERSION}/Fulcrum-${FULCRUM_VERSION}-shasums.txt.asc
    wget -q https://github.com/cculianu/Fulcrum/releases/download/v${FULCRUM_VERSION}/Fulcrum-${FULCRUM_VERSION}-shasums.txt
    wget -q https://github.com/Electron-Cash/keys-n-hashes/raw/master/pubkeys/calinkey.txt

    gpg --import calinkey.txt >/dev/null 2>&1
    gpg --verify Fulcrum-${FULCRUM_VERSION}-shasums.txt.asc >/dev/null 2>&1
    grep 'x86_64-linux.tar.gz' Fulcrum-${FULCRUM_VERSION}-shasums.txt | sha256sum --check

    tar -xvf Fulcrum-${FULCRUM_VERSION}-x86_64-linux.tar.gz >/dev/null
  " || print_error "Fulcrum download/verification failed"

  # Install binaries as root
  install -m 0755 -o root -g root -t /usr/local/bin \
    "$FULCRUM_HOME/Fulcrum-$FULCRUM_VERSION-x86_64-linux/Fulcrum" \
    "$FULCRUM_HOME/Fulcrum-$FULCRUM_VERSION-x86_64-linux/FulcrumAdmin"

  /usr/local/bin/Fulcrum --version >/dev/null 2>&1 || true
  print_message "Fulcrum installed successfully to /usr/local/bin"
fi

# -----------------------------
# Create deploy user
# -----------------------------
print_message "Creating deploy user: $DEPLOY_USER"
if ! id "$DEPLOY_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$DEPLOY_USER"
  usermod -aG sudo "$DEPLOY_USER"
  print_message "User $DEPLOY_USER created successfully"
else
  print_message "User $DEPLOY_USER already exists"
fi

# -----------------------------
# Set up SSH authorized_keys for deploy user
# (Preserves original security posture: DO NOT generate or store private keys on VPS.)
# -----------------------------
print_message "Setting up SSH for deploy user..."
mkdir -p "$DEPLOY_HOME/.ssh"
chmod 700 "$DEPLOY_HOME/.ssh"
chown "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_HOME/.ssh"

AUTHORIZED_KEYS="$DEPLOY_HOME/.ssh/authorized_keys"
if [ ! -s "$AUTHORIZED_KEYS" ]; then
  print_message "No authorized SSH key found."
  print_message "Paste the *public* SSH key you want to use for $DEPLOY_USER (e.g. contents of ~/.ssh/id_ed25519.pub):"
  read -r SSH_PUB_KEY
  [ -z "$SSH_PUB_KEY" ] && print_error "No SSH public key provided"
  echo "$SSH_PUB_KEY" > "$AUTHORIZED_KEYS"
  chmod 600 "$AUTHORIZED_KEYS"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTHORIZED_KEYS"
  print_message "Public key added to authorized_keys"
else
  print_message "SSH key already present in authorized_keys — skipping prompt"
fi

# -----------------------------
# Add deploy user to sudoers (NOPASSWD)
# -----------------------------
print_message "Adding $DEPLOY_USER to sudoers with no password..."
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deployer
chmod 440 /etc/sudoers.d/deployer
visudo -c || print_error "Sudoers file syntax check failed"

# -----------------------------
# Harden SSH: disable password auth, keep root key login allowed
# -----------------------------
print_message "Hardening SSH (disable password auth)..."
SSH_HARDEN_FILE="/etc/ssh/sshd_config.d/99-hardening.conf"
cat > "$SSH_HARDEN_FILE" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
EOF

systemctl reload ssh || systemctl reload sshd || true

# -----------------------------
# Configure firewall (UFW)
# -----------------------------
print_message "Configuring firewall..."
ufw --force enable

# SSH + basic web ports (useful for cert issuance, reverse proxy, etc.)
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp

# BCHN Chipnet P2P
ufw allow "${BCHN_CHIPNET_P2P_PORT}"/tcp

# Fulcrum ports (repo defaults)
ufw allow "${FULCRUM_PORT_SSL}"/tcp
ufw allow "${FULCRUM_PORT_TCP}"/tcp
ufw allow "${FULCRUM_PORT_WSS}"/tcp

# -----------------------------
# Enable fail2ban (base protection; jail configuration can be managed via Ansible)
# -----------------------------
print_message "Enabling fail2ban..."
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl start fail2ban >/dev/null 2>&1 || true

# -----------------------------
# Output data needed for GitHub Actions Secrets
# -----------------------------
print_message "VPS setup completed successfully!"
print_message "Data for GitHub Actions Secrets:"
echo "=========================="
echo "VAULT_SERVER_IP: $SERVER_IP"
echo "VAULT_DEPLOY_USER: $DEPLOY_USER"
echo "VAULT_RPC_PASSWORD: $(openssl rand -base64 24)"
echo "=========================="
print_message "IMPORTANT:"
print_message "For GitHub secret VPS_SSH_KEY, use the *private* key that corresponds to the public key you pasted for $DEPLOY_USER."
print_message "Do NOT generate or store private keys on the VPS."
print_message "Next steps:"
print_message "1. Add VPS_SSH_KEY (from your local machine) to GitHub Actions Secrets."
print_message "2. Add VAULT_SERVER_IP, VAULT_DEPLOY_USER, and VAULT_RPC_PASSWORD to GitHub Actions Secrets."
print_message "3. Push to main (or run workflow_dispatch) to deploy via Ansible."
