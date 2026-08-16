# IAC AI Agent Deployer

Infrastructure as Code (IaC) solution to automatically provision and configure Virtual Machines on a **Proxmox VE** cluster, tailored for hosting autonomous AI Agents (such as OpenClaw or Hermes) powered by **Ollama** (locally or via cloud subscriptions).

---

## 🎯 Goal of the Project

1. **Infrastructure Provisioning (OpenTofu / Terraform)**: Automate the creation of one or multiple VMs on Proxmox VE (CPU, RAM, disks, network interfaces, and optional GPU/PCI passthrough) using Ubuntu Cloud-Init images.
2. **Environment Configuration (Ansible)**: Configure the provisioned VMs with system updates, Node.js (via NVM), Docker, UFW firewall, system utilities, and Ollama.

---

## 🛠 Prerequisites

- A running **Proxmox VE** instance with an API Token.
- **OpenTofu** (or **Terraform**) installed on your workstation.
- **Ansible** installed on your workstation.
- A Proxmox directory datastore with `snippets` enabled (e.g. `local`) for Cloud-Init configuration.

---

## ⚙️ Configuration

Initialize the configuration files before deploying:

### 1. Infrastructure (`iac/terraform.tfvars`)

```bash
cp iac/terraform.tfvars.example iac/terraform.tfvars
```

Edit `iac/terraform.tfvars` with your settings:
- `proxmox_api_url` & `proxmox_api_token`: Proxmox API endpoint and API token.
- `ssh_public_key`: Public SSH key injected via Cloud-Init for the `ubuntu` user.
- `vm_config`: Map of VM configurations (target node, IP addresses, vCPUs, RAM, disk size, and optional `pci_devices` for GPU passthrough).

### 2. Ansible Inventory (`ansible/inventory/inventory.yml`)

```bash
cp ansible/inventory/inventory.yml.example ansible/inventory/inventory.yml
```

Set `ansible_host` to your VM's IP address.

### 3. Ansible Settings (`ansible/group_vars/all.yml`)

```bash
cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
```

Customize global settings as needed:
- `ollama_enabled`: Set to `false` if using an external inference server (default: `true`).
- `ollama_models`: List of models to pull automatically (e.g. `["kimi-k2.7-code:cloud", "qwen3-embedding:0.6b"]`).
- `ollama_signin_required`: Set to `true` if pulling Ollama Cloud models requiring interactive OAuth browser login (default: `false`).
- `nvm_node_version`: Node.js version to install (default: `"lts/*"`).
- `essential_packages_extra`: Additional system packages to install (e.g. `["nvtop", "btop", "zsh"]`).
- `system_timezone_value`: Timezone (default: `"Europe/Paris"`).

---

## 🚀 Deployment

### Step 1: Provision Infrastructure

```bash
cd iac
tofu init    # or `terraform init`
tofu apply   # or `terraform apply`
```

### Step 2: Configure the VM

Once OpenTofu finishes provisioning:

```bash
cd ../ansible
ansible-playbook -i inventory/inventory.yml playbook.yml
```

The playbook will:
- Wait for Cloud-Init initial boot to complete.
- Update and upgrade all system packages.
- Install essential tools, Docker, UFW firewall, and NVM/Node.js.
- Install Ollama and pull configured models (if enabled).
- Reboot the machine automatically only if pending kernel updates require it.

### Step 3: Connect & Launch Agent

```bash
ssh ubuntu@<VM_IP_ADDRESS>
```

Launch your AI agent (e.g. OpenClaw):

```bash
ollama launch openclaw
```

---

## 🔒 Security & Firewall

The playbook configures **UFW** and Docker iptables isolation to prevent Docker container ports from being exposed directly to external interfaces while preserving local access.

---

## 🙌 Acknowledgments

Inspired by the [openclaw-ansible](https://github.com/openclaw/openclaw-ansible/) repository.
