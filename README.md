# IAC AI Agent Deployer

This project provides an Infrastructure as Code (IaC) solution to automatically provision and configure Virtual Machines (VMs) on a Proxmox cluster, specifically tailored for running an AI Agent (such as [OpenClaw](https://openclaw.ai) or Hermes) powered by [Ollama](https://ollama.com) (locally or via a cloud subscription).

## 🎯 Goal of the Project

The primary goal is to use **OpenTofu** (or **Terraform**) to spin up one or multiple virtual machines on Proxmox, and configure their operating environments using **Ansible** so they are perfectly prepared to host an AI agent. Both the Terraform and Ansible configurations are designed to accept lists and mappings, making it perfectly possible and easy to deploy and manage several VMs simultaneously.

> **Note:** The final installation of the AI agent itself (like OpenClaw) is not fully automated in this project because Ollama currently lacks a headless mode for the initial agent installation and authentication. It only provides headless commands once the agent is fully set up. However, this repository serves as an educational project, focusing purely on automating the underlying infrastructure, while keeping the AI setup itself manual.

## ⚠️ Security Notice (Firewall)

**No software firewall (like UFW or iptables) is configured by default via these playbooks.** In its original setup, this infrastructure relies on an isolated VLAN and a physical hardware firewall to manage inbound and outbound traffic. 

It is highly recommended **NOT** to grant your AI agent access to your internal local network unless explicitly required. Rely on your own hypervisor-level network separation or physical firewalls to secure and isolate the VM.

## 🛠 Prerequisites

- A running **Proxmox VE** instance.
- An API Token on Proxmox with the appropriate permissions.
- **OpenTofu** (or **Terraform**) installed on your workstation.
- **Ansible** installed on your workstation.

---

## ⚙️ Configuration Files

Before deploying, there are three main configuration files you need to initialize:

### 1. Infrastructure Configuration (`iac/terraform.tfvars`)

Copy the example file to create your own Proxmox/VM configuration:
```bash
cp iac/terraform.tfvars.example iac/terraform.tfvars
```
> **💡 Tip regarding default values:** Any variable that is commented out in `terraform.tfvars.example` indicates the current default value used by the modules. Some of these default values are localized for a French environment (e.g., `vm_keyboard_layout = "fr"` in Terraform, and `system_timezone_value = "Europe/Paris"` in Ansible). Make sure to uncomment and modify these values if you need an English/QWERTY environment or a different timezone.

**What to modify:**
- `proxmox_api_url` & `proxmox_api_token`: Your Proxmox host API endpoint and authentication token.
- `ssh_public_key`: The RSA/Ed25519 public key that will be seeded via cloud-init for SSH access.
- `vm_config`: Change the IP address (`address`), gateway, node name, etc. to match your network. You can declare multiple VMs in this block since it accepts a map of configurations.
- *(Optional)* Adjust resources like `vm_cpu_cores`, `vm_memory_mb`, or `vm_disk_size_gb` to accommodate your specific machine learning workload.
- *(Optional)* Configure DNS settings by uncommenting `dns_servers` and `dns_domain` to inject custom DNS settings via Cloud-Init.

### 2. Ansible Inventory (`ansible/inventory/inventory.yml`)

Copy the example inventory file:
```bash
cp ansible/inventory/inventory.yml.example ansible/inventory/inventory.yml
```
**What to modify:**
- `ansible_host`: Replace the example value with the exact IP address you assigned to your VM in your `terraform.tfvars` file.
- `ansible_user`: Ensure this matches the `vm_user` specified in Terraform (defaults to `openclaw`).

### 3. Ansible Global Settings (`ansible/group_vars/all.yml`)

Open this file to customize:
- `ollama_models`: Add or remove the default models you want Ollama to pull during setup (e.g., `glm-5.1:cloud`).
- `openclaw_model`: Define the primary AI model used by OpenClaw to ensure consistency across the setup.
- `system_timezone_value`: Set your desired system timezone (defaults to `Europe/Paris`, change it to match your local region).
- `nvm_version`: Specify the Node Version Manager version if an update is needed.

---

## 🚀 Deployment Instructions

### Step 1: Provision the Infrastructure

Navigate to the `iac` folder, initialize OpenTofu/Terraform and deploy the configurations:

```bash
cd iac

# Initialize the project (downloads providers)
tofu init  # or `terraform init`

# Apply the infrastructure
tofu apply # or `terraform apply`
```
Type `yes` when prompted. Wait for the VM to be cloned and initialized by Proxmox/Cloud-Init.

### Step 2: Configure the VM

Once the VM is fully booted and accessible over SSH, move to the Ansible directory and run the playbook. This will install system updates, Node.js via NVM, Ollama, and handle system configurations.

```bash
cd ../ansible
ansible-playbook -i inventory/inventory.yml playbook.yml
```

*Note: The playbook will automatically reboot the VM if any kernel updates were applied.*

### Step 3: Install the AI Agent Manually

Connect to your newly provisioned and configured virtual machine:

```bash
ssh openclaw@<VM_IP_ADDRESS>
```

Finally, initialize your agent (e.g., OpenClaw):
```bash
ollama launch openclaw
```
Follow the interactive prompts to authenticate and finish setting up your agent.
