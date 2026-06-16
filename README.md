# Bitcoin Cash Node Ubuntu Deployment

This repository provides an automated and secure setup for running Bitcoin Cash Node (BCHN) on Ubuntu, supporting Chipnet (testnet), Mainnet, and Tempnet networks, along with Fulcrum as an Electrum server. It uses a hardened VPS provisioning script (`setup.sh`), Ansible playbooks for configuration, and GitHub Actions for CI/CD-style deployments.

## Features

- Automated deployment of BCHN on Ubuntu 22.04+ (builds from bitjson's tempnet branch for Tempnet support).
- Configurations for Chipnet, Mainnet, and Tempnet with customized `bitcoin.conf` files.
- Fulcrum Electrum server integration for each network (with SSL/WSS support).
- Hardened systemd services with security features (e.g., `PrivateTmp`, `ProtectSystem=full`).
- GitHub Actions workflow for automated deployments using secrets.
- SSH key-based access; disables root/password logins.
- Firewall configuration with UFW.

## Requirements

### VPS Requirements
- Ubuntu 22.04 or 24.04 (fresh install recommended).
- At least 4GB RAM (for building BCHN; script adds swap if lower).
- SSH access as root for initial setup.
- Public IP address.
- Sufficient storage (e.g., 500GB+ SSD for blockchain data across networks).

### Local Requirements
- Git installed.
- SSH key pair generated on your local machine (for VPS access and GitHub secrets).
- GitHub account with a repository (fork or create one from this repo).
- Basic knowledge of Git, SSH, GitHub Actions, and terminal commands.

## Quick Start

### 1. Provision Your VPS
- Create a VPS (e.g., via Hostinger, DigitalOcean, or AWS) running Ubuntu 22.04+.
- SSH into it as root: `ssh root@your-vps-ip`.
- Clone this repository: `git clone https://github.com/yourusername/bitcoin-cash-node-ubuntu.git`.
- Navigate to the repo: `cd bitcoin-cash-node-ubuntu`.
- Make the script executable: `chmod +x setup.sh`.
- Run the script: `sudo ./setup.sh`.

The script will:
- Update the system and install dependencies (including Ansible, build tools, BCHN from tempnet branch, and Fulcrum).
- Create a `deployer` user with sudo access.
- Prompt for your SSH public key (generate locally with `ssh-keygen` if needed; paste the contents of `~/.ssh/id_rsa.pub`).
- Set up UFW firewall with necessary ports.
- Output values for GitHub secrets (e.g., `VAULT_SERVER_IP`, `VAULT_DEPLOY_USER`, `VAULT_RPC_PASSWORD`).

**Note**: If RAM is low, the script adds temporary swap for building BCHN.

### 2. Configure GitHub Repository Secrets
After `setup.sh` completes, it outputs the server connection values and a generated RPC password. Add them to your GitHub repo:

- Go to your repo on GitHub: Settings > Secrets and variables > Actions > New repository secret.
- Create these secrets:
  - `VPS_SSH_KEY`: A dedicated deploy-only SSH private key from your local machine. The matching public key is the one you pasted into `setup.sh`. **Do not use a personal SSH key, and do not generate or store private keys on the VPS.**
  - `VAULT_SERVER_IP`: The VPS public IP (output from script).
  - `VAULT_DEPLOY_USER`: Usually "deployer" (output from script).
  - `VAULT_RPC_PASSWORD`: Generated RPC password (output from script). This is shared across networks; for Mainnet, optionally add `VAULT_RPC_PASSWORD_MAINNET` for a separate password.

**Security Warning**: Never commit secrets to the repo. Use `.gitignore` to exclude them. Rotate passwords regularly.

### 3. Customize Configurations (Optional)
- Edit Ansible vars if needed (e.g., ports, users):
  - `ansible/roles/bchn_config/vars/main.yml`: BCHN settings.
  - `ansible/roles/fulcrum_config/vars/main.yml`: Fulcrum settings.
- For custom RPC passwords per network, add more GitHub secrets (e.g., `VAULT_RPC_PASSWORD_MAINNET`) and update lookups in vars files.
- Commit and push changes to trigger deployments.

### 4. Deploy via GitHub Actions
- Push to the `main` branch: This triggers `.github/workflows/deploy.yml`.
- Or manually run: Go to Actions > Deploy BCHN Chipnet Configuration > Run workflow.

The workflow:
- Checks out the code.
- Sets up SSH with your secrets.
- Runs Ansible playbooks to configure BCHN and Fulcrum services.

### 5. Verify Deployment
- SSH as deployer: `ssh deployer@your-vps-ip`.
- Check services: `sudo systemctl status bitcoind-chipnet`, `bitcoind-mainnet`, `bitcoind-tempnet`, `fulcrum-chipnet`, `fulcrum-tempnet`.
- View logs: `journalctl -u bitcoind-chipnet -f`.
- Test RPC (local only): `bitcoin-cli -chipnet getblockchaininfo`.
- Fulcrum: Connect via Electrum wallet (use ports like 50002 for Chipnet WSS).

## Configurations Overview

### bitcoin.conf Examples (Templated)
- Chipnet: Pruned, txindex enabled for Fulcrum.
- Mainnet: Pruned.
- Tempnet: txindex enabled.

Full templates in `ansible/roles/bchn_config/templates/`.

### Systemd Services
- Located in `/etc/systemd/system/` (e.g., `bitcoind-chipnet.service`).
- Auto-restart, hardened.

### Fulcrum
- Data dirs: `~/fulcrum_db_chipnet`, etc.
- Self-signed certs generated.
- Ports: 50001 (TCP), 50000 (SSL), 50002 (WSS) for Chipnet; similar for others.

## Troubleshooting
- Deployment fails? Check GitHub Actions logs for Ansible errors.
- Service not starting? Validate configs: `bitcoind -conf=/path/to/bitcoin.conf -chipnet -printtoconsole`.
- Firewall issues: `sudo ufw status`.
- Build errors in `setup.sh`: Ensure sufficient RAM/swap.

## Security Notes
- RPC access is local-only (127.0.0.1).
- Use strong, unique passwords.
- Monitor logs and update regularly.

## License
MIT License.
