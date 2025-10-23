#!/bin/bash

# Bash script to configure a Hostinger VPS for Ansible DevOps deployments and GitHub Actions
# Run as root user via SSH
# Target: Ubuntu 22.04/24.04 VPS
# Prepares VPS for Bitcoin Cash Node (Chipnet/Mainnet/Tempnet) with secrets managed via GitHub Secrets
# Updated for Tempnet: Builds from bitjson's tempnet branch
# Added Fulcrum installation for Electrum server support

set -e

# Define variables
DEPLOY_USER="deployer"  # Matches VAULT_DEPLOY_USER
DEPLOY_HOME="/home/$DEPLOY_USER"
SSH_PORT="22"
FULCRUM_USER="fulcrum"
FULCRUM_HOME="/home/$FULCRUM_USER"
FULCRUM_VERSION="1.12.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

print_message() { echo -e "${GREEN}[INFO] $1${NC}"; }
print_error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# Check if running as root
[ "$(id -u)" -ne 0 ] && print_error "This script must be run as root"

# Robust IPv4 detection (for VAULT_SERVER_IP)
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

# Install essential packages (including acl for Ansible become_user ACL support)
print_message "Installing essential packages..."
apt install -y python3 python3-pip git curl wget unzip software-properties-common apt-transport-https ca-certificates gnupg lsb-release openssl gpg acl

# Install Ansible
print_message "Installing Ansible..."
apt install -y ansible
ansible --version || print_error "Ansible installation failed"

# Install build dependencies for BCHN tempnet branch
print_message "Installing build dependencies for Bitcoin Cash Node tempnet branch..."
apt install -y build-essential cmake git libboost-chrono-dev libboost-filesystem-dev libboost-test-dev libboost-thread-dev libevent-dev libminiupnpc-dev libssl-dev libzmq3-dev help2man ninja-build python3 libgmp-dev zlib1g-dev

# Build and install Bitcoin Cash Node from tempnet branch
if [ -f /usr/local/bin/bitcoind ]; then
  print_message "Bitcoin Cash Node already installed at /usr/local/bin/bitcoind, skipping build"
else
  print_message "Building Bitcoin Cash Node from tempnet branch..."
  cd ~
  rm -rf bchn  # Remove old if exists
  git clone https://github.com/bitjson/bchn.git -b tempnet
  cd bchn
  mkdir build && cd build
  cmake -GNinja .. -DBUILD_BITCOIN_WALLET=OFF -DBUILD_BITCOIN_QT=OFF -DENABLE_NATPMP=OFF -DCMAKE_BUILD_TYPE=Release

  # Add swap if low RAM (auto-detect <4GB)
  TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
  if [ "$TOTAL_RAM" -lt 4000 ]; then
    print_message "Low RAM detected ($TOTAL_RAM MB) - Adding 4GB swap..."
    dd if=/dev/zero of=/swapfile bs=1M count=4096
    mkswap /swapfile
    swapon /swapfile
  fi

  ninja || print_error "Build failed - Check dependencies or RAM"
  ninja install
  /usr/local/bin/bitcoind --version || print_error "Bitcoin Cash Node installation failed"
  print_message "Bitcoin Cash Node tempnet branch installed successfully to /usr/local/bin"
fi

# Install Fulcrum
if [ -f /usr/local/bin/Fulcrum ]; then
  print_message "Fulcrum already installed at /usr/local/bin/Fulcrum, skipping installation"
else
  print_message "Installing Fulcrum Electrum server..."
  # Create fulcrum user
  if ! id "$FULCRUM_USER" &>/dev/null; then
      useradd -m -s /bin/bash "$FULCRUM_USER"
      print_message "User $FULCRUM_USER created successfully"
  else
      print_message "User $FULCRUM_USER already exists"
  fi

  # Switch to fulcrum user for downloads
  su - $FULCRUM_USER -c "
    cd ~
    wget https://github.com/cculianu/Fulcrum/releases/download/v$FULCRUM_VERSION/Fulcrum-$FULCRUM_VERSION-x86_64-linux.tar.gz
    wget https://github.com/cculianu/Fulcrum/releases/download/v$FULCRUM_VERSION/Fulcrum-$FULCRUM_VERSION-shasums.txt.asc
    wget https://github.com/cculianu/Fulcrum/releases/download/v$FULCRUM_VERSION/Fulcrum-$FULCRUM_VERSION-shasums.txt
    wget https://github.com/Electron-Cash/keys-n-hashes/raw/master/pubkeys/calinkey.txt

    # Verify
    gpg --import calinkey.txt
    gpg --verify Fulcrum-$FULCRUM_VERSION-shasums.txt.asc
    grep 'x86_64-linux.tar.gz' Fulcrum-$FULCRUM_VERSION-shasums.txt | sha256sum --check

    # Extract
    tar -xvf Fulcrum-$FULCRUM_VERSION-x86_64-linux.tar.gz
  "

  # Install binaries as root
  install -m 0755 -o root -g root -t /usr/local/bin $FULCRUM_HOME/Fulcrum-$FULCRUM_VERSION-x86_64-linux/Fulcrum $FULCRUM_HOME/Fulcrum-$FULCRUM_VERSION-x86_64-linux/FulcrumAdmin
  print_message "Fulcrum installed successfully to /usr/local/bin"
fi

# Create deploy user
print_message "Creating deploy user: $DEPLOY_USER"
if ! id "$DEPLOY_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$DEPLOY_USER"
    usermod -aG sudo "$DEPLOY_USER"
    print_message "User $DEPLOY_USER created successfully"
else
    print_message "User $DEPLOY_USER already exists"
fi

# Set up SSH for deploy user
print_message "Setting up SSH for deploy user..."
mkdir -p "$DEPLOY_HOME/.ssh"
chmod 700 "$DEPLOY_HOME/.ssh"
chown "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_HOME/.ssh"

AUTHORIZED_KEYS="$DEPLOY_HOME/.ssh/authorized_keys"

if [ ! -s "$AUTHORIZED_KEYS" ]; then
    print_message "No authorized SSH key found. Please paste the public SSH key you want to use for $DEPLOY_USER:"
    read -r SSH_PUB_KEY

    echo "$SSH_PUB_KEY" > "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
    chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTHORIZED_KEYS"
    print_message "Public key added to authorized_keys"
else
    print_message "SSH key already present in authorized_keys — skipping prompt"
fi

# Add deploy user to sudoers
print_message "Adding $DEPLOY_USER to sudoers with no password..."
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deployer
chmod 440 /etc/sudoers.d/deployer
visudo -c || print_error "Sudoers file syntax check failed"

# Configure firewall (add Tempnet ports and Fulcrum ports)
print_message "Configuring firewall..."
ufw --force enable
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 48333/tcp  # Chipnet P2P port
ufw allow 58333/tcp  # Tempnet P2P port
ufw allow 50002/tcp  # Fulcrum SSL for Chipnet
ufw allow 50004/tcp  # Fulcrum SSL for Tempnet

# Output data needed for GitHub Actions (aligns with your secrets)
print_message "VPS setup completed successfully!"
print_message "Data for GitHub Actions Secrets:"
echo "=========================="
echo "VPS_SSH_KEY:"  # Private key (copy from VPS: cat $DEPLOY_HOME/.ssh/id_rsa)
cat "$DEPLOY_HOME/.ssh/id_rsa"
echo "=========================="
echo "VAULT_SERVER_IP: $SERVER_IP"
echo "VAULT_DEPLOY_USER: $DEPLOY_USER"
echo "VAULT_RPC_PASSWORD: $(openssl rand -base64 24)"
echo "=========================="
print_message "Next steps:"
print_message "1. Add the above VPS_SSH_KEY (private key) to GitHub Actions Secrets as 'VPS_SSH_KEY'."
print_message "2. Add VAULT_SERVER_IP, VAULT_DEPLOY_USER, and VAULT_RPC_PASSWORD to GitHub Actions Secrets."
print_message "3. Ensure the repository is public and Ansible playbook is triggered via GitHub Actions."
print_message "4. Ansible will configure Fulcrum services post-setup."