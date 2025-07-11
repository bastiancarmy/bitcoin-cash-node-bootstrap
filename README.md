# Bitcoin Cash Node - Ubuntu Deployment

This repository provides an automated and secure setup for running a Bitcoin Cash (BCHN) node on the Chipnet test network. The setup includes a hardened VPS provisioning script, Ansible playbooks for configuration, and a GitHub Actions CI workflow for infrastructure-as-code-style deployments.

## Features

- Automated deployment of Bitcoin Cash Node on Ubuntu (22.04+)
- Chipnet support with customized bitcoin.conf
- Hardened systemd service with security hardening
- GitHub Actions integration with secrets-based provisioning
- Uses SSH key-based login and disables root/password access
- Secure Ansible-based infrastructure provisioning

## Quick Start

### 1. Provision and SSH into Your VPS

Create a VPS (for example, using Hostinger) running Ubuntu 22.04 or later.

SSH into it as root:
```
ssh root@your-vps-ip
```

### 2. Run setup.sh as Root

Clone this repository and run the provisioning script:

```
git clone https://github.com/yourusername/bitcoin-cash-node-ubuntu.git
cd bitcoin-cash-node-ubuntu
chmod +x setup.sh
sudo ./setup.sh
```

This script will:

- Install essential packages and Ansible
- Install Bitcoin Cash Node (bitcoind)
- Create a deploy user with SSH key-based login
- Generate SSH and runtime secrets for GitHub Actions

### 3. Configure GitHub Repository Secrets

After `setup.sh` completes, it will output the following values:

- VPS_SSH_PUBLIC_KEY
- VAULT_SERVER_IP
- VAULT_DEPLOY_USER
- VAULT_RPC_PASSWORD

Save these values and add them to your GitHub repository under:

Settings > Secrets and variables > Actions

Use the following secret keys:

- VPS_SSH_KEY: Private key from `/home/deployer/.ssh/id_rsa` (you can extract this from the VPS if needed)
- VAULT_SERVER_IP: Output from setup.sh
- VAULT_DEPLOY_USER: Usually "deployer"
- VAULT_RPC_PASSWORD: Output from setup.sh

### 4. Deploy via GitHub Actions

Any push to the `main` branch will automatically trigger the Ansible deployment using the GitHub Actions workflow defined in `.github/workflows/deploy.yml`.

You can also manually trigger a run from the GitHub Actions UI by selecting "Deploy BCHN Chipnet Configuration" and clicking "Run workflow".

## Configuration: bitcoin.conf

The `bitcoin.conf` file is managed by Ansible and rendered from a Jinja2 template at:

`ansible/roles/bchn_config/templates/bitcoin.conf.j2`

The rendered configuration for Chipnet includes:

```
# bitcoin.conf for Bitcoin Cash Node (Chipnet)
server=1
rpcuser=rewt
rpcpassword=<value from VAULT_RPC_PASSWORD>
rpcallowip=127.0.0.1
chipnet=1
prune=10000

[chipnet]
rpcport=48332
port=48333
onion=48334
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333
```

To change configuration values, edit the variables file at:

`ansible/roles/bchn_config/vars/main.yml`

Or modify the environment variables in your GitHub repository secrets.

## Systemd Service

Ansible also creates a secure systemd service for bitcoind located at:

`/etc/systemd/system/bitcoind.service`

Key features of the service unit:

- Executes bitcoind with Chipnet configuration
- Automatically restarts on failure
- Enforces Linux hardening options:
  - `PrivateTmp`
  - `ProtectSystem=full`
  - `NoNewPrivileges`
  - `MemoryDenyWriteExecute`

To view logs:

```
journalctl -u bitcoind -f
```

To manually start or stop:

```
sudo systemctl start bitcoind
sudo systemctl stop bitcoind
```

## Requirements

- Ubuntu 22.04
- SSH access to the VPS as root (for initial provisioning)
- GitHub repository with Actions enabled
- GitHub Secrets configured as described above
- Basic familiarity with Git, SSH, and GitHub Actions

## License

This project is licensed under the MIT License.