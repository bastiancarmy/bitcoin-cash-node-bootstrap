#!/bin/bash

# Bash script to configure a Hostinger VPS for Ansible DevOps deployments and GitHub Actions
# Run as root user via SSH
# Target: Ubuntu 22.04/24.04 VPS
# Prepares VPS for Bitcoin Cash Node (Chipnet) with secrets managed via GitHub Secrets

set -e

# Define variables
DEPLOY_USER="deployer"
DEPLOY_HOME="/home/$DEPLOY_USER"
SSH_PORT="22"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

print_message() { echo -e "${GREEN}[INFO] $1${NC}"; }
print_error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# Check if running as root
[ "$(id -u)" -ne 0 ] && print_error "This script must be run as root"

# Robust IPv4 detection
print_message "Obtaining SERVER_IP..."
SERVER_IP=""
for method in \
  "curl -s ifconfig.me" \
  "curl -s https://api.ipify.org" \
  "ip route get 1.1.1.1 | awk '{print $7}' | head -1" \
  "hostname -I | awk '{print $1}'"; do
  SERVER_IP=$(bash -c "$method")
  if [[ -n "$SERVER_IP" && "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print_message "Detected SERVER_IP: $SERVER_IP"
    break
  fi
done
[ -z "$SERVER_IP" ] && print_error "Failed to obtain SERVER_IP"

# Update system packages
print_message "Updating system packages..."
apt update && apt upgrade -y

# Install essential packages
print_message "Installing essential packages..."
apt install -y python3 python3-pip git curl wget unzip software-properties-common apt-transport-https ca-certificates gnupg lsb-release

# Install Ansible
print_message "Installing Ansible..."
apt install -y ansible
ansible --version || print_error "Ansible installation failed"

# Install Bitcoin Cash Node
print_message "Installing Bitcoin Cash Node..."
add-apt-repository -y ppa:bitcoin-cash-node/ppa
apt update
apt install -y bitcoind
bitcoind --version || print_error "Bitcoin Cash Node installation failed"

# Create deploy user
print_message "Creating deploy user: $DEPLOY_USER"
if ! id "$DEPLOY_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$DEPLOY_USER"
    usermod -aG sudo "$DEPLOY_USER"
    print_message "User $DEPLOY_USER created successfully"
else
    print_message "User $DEPLOY_USER already exists"
fi

# Set up SSH
print_message "Setting up SSH for deploy user..."
mkdir -p "$DEPLOY_HOME/.ssh"
chmod 700 "$DEPLOY_HOME/.ssh"
chown "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_HOME/.ssh"

if [ ! -f "$DEPLOY_HOME/.ssh/id_rsa" ]; then
    print_message "Generating SSH key for $DEPLOY_USER..."
    sudo -u "$DEPLOY_USER" ssh-keygen -t rsa -b 4096 -f "$DEPLOY_HOME/.ssh/id_rsa" -N ""
fi

print_message "Adding public key to authorized_keys..."
PUBLIC_KEY=$(cat "$DEPLOY_HOME/.ssh/id_rsa.pub")
AUTHORIZED_KEYS="$DEPLOY_HOME/.ssh/authorized_keys"
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTHORIZED_KEYS"
if ! grep -Fx "$PUBLIC_KEY" "$AUTHORIZED_KEYS" > /dev/null; then
    echo "$PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
fi

# Add deploy user to sudoers
print_message "Adding $DEPLOY_USER to sudoers with no password..."
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deployer
chmod 440 /etc/sudoers.d/deployer
visudo -c || print_error "Sudoers file syntax check failed"

# Configure firewall
print_message "Configuring firewall..."
ufw --force enable
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 48333/tcp  # Chipnet P2P port

# Output data needed for GitHub Actions
print_message "VPS setup completed successfully!"
print_message "Data for GitHub Actions Secrets:"
echo "=========================="
echo "VPS_SSH_PUBLIC_KEY:"
cat "$DEPLOY_HOME/.ssh/id_rsa.pub"
echo "=========================="
echo "VAULT_SERVER_IP: $SERVER_IP"
echo "VAULT_DEPLOY_USER: $DEPLOY_USER"
echo "VAULT_RPC_PASSWORD: $(openssl rand -base64 24)"
echo "=========================="
print_message "Next steps:"
print_message "1. Add the above VPS_SSH_PUBLIC_KEY to GitHub Actions Secrets as 'VPS_SSH_KEY' (use the private key from $DEPLOY_HOME/.ssh/id_rsa on the VPS)."
print_message "2. Add VAULT_SERVER_IP, VAULT_DEPLOY_USER, and VAULT_RPC_PASSWORD to GitHub Actions Secrets."
print_message "3. Ensure the repository is public and Ansible playbook is triggered via GitHub Actions."