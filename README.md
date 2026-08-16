# IAC AI Agent Deployer

Infrastructure as Code (IaC) solution to automatically provision and configure hardened Virtual Machines on a **Proxmox VE** cluster, tailored for hosting autonomous AI Agents (such as **Hermes**, **OpenClaw**, **Smolagents**, etc.) with rootless sandboxing via **Podman + Google gVisor (`runsc`)**, Docker/Compose compatibility layer, modern Python tooling via **`uv` (Python 3.14)**, QEMU Guest Agent integration, and local/cloud LLM inference with **Ollama**.

---

## 🎯 Goal of the Project

1. **Infrastructure Provisioning (OpenTofu / Terraform)**: Automate the creation of one or multiple VMs on Proxmox VE (CPU, RAM, disks, network interfaces, and optional GPU/PCI passthrough) using Ubuntu Cloud-Init images with native `qemu-guest-agent` support.
2. **Hardened Environment Configuration (Ansible)**:
   - **Harness-Agnostic Setup**: Configurable agent harness name (`harness_name: "hermes"` or `"openclaw"`).
   - **Least-Privilege Security**: Dedicated non-root user with `0750` home directory permissions and scoped sudo permissions (`restart` only) to prevent privilege escalation, denial of service, and credential dumping.
   - **Continuous Operation**: `systemd` lingering enabled (`loginctl enable-linger`) with D-Bus/XDG user session for 24/7 background agent daemons.
   - **Kernel-Isolated Sandboxing ("Secure by Default")**: Rootless **Podman** container engine configured with Google **gVisor (`runsc`) as the default runtime**. Every container (`podman run` or `docker run`) automatically runs in a memory-safe user-space kernel sandbox.
   - **Full Docker & Compose Compatibility**: Drop-in `docker`, `docker-compose`, and `docker compose` compatibility via `podman-docker` and `podman-compose` with `DOCKER_HOST` socket integration.
   - **Multi-Layer Defense in Depth**:
     - **SSH Hardening**: Password authentication disabled, root login disabled, `AllowUsers` whitelist, rate-limiting, brute-force protection with **Fail2ban**, and Post-Quantum cryptography (`sntrup761x25519`).
     - **Resource Limits & Anti-DoS**: `limits.d` protection against fork bombs (`nproc 2048`), file descriptor exhaustion (`nofile 65536`), and core dump suppression.
     - **OS & Kernel Hardening**: `sysctl` kernel protections, memory sandbox (`yama.ptrace_scope = 1`), AppArmor enforce mode, `libpam-pwquality`, obsolete kernel modules blacklisting (`dccp`, `sctp`, `firewire`), and secure default `umask 027`.
     - **Automated Security Updates**: `unattended-upgrades` with `apt-daily.timer` and automatic kernel cleanups.
     - **Ollama Security**: Explicit localhost binding (`127.0.0.1:11434`) via systemd override to prevent external network exposure.
   - **Modern Python & Developer Stack**: **`uv`** standalone manager with **Python 3.14**, Node.js (via NVM), essential search & monitoring tools (`ripgrep`, `fd-find`, `btop`, `nvtop`), UFW firewall, and Ollama with automated model downloading.

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
- `ssh_public_key`: Public SSH key injected via Cloud-Init for the admin user (`ubuntu`).
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
- `harness_name`: Name of the agent / dedicated non-root user (e.g. `"hermes"`, `"openclaw"`, default: `"hermes"`).
- `gvisor_enabled`: Enable Google gVisor (`runsc`) runtime in Podman (default: `true`).
- `gvisor_default`: Use gVisor (`runsc`) as the default OCI runtime for all containers (default: `true`).
- `uv_python_version`: Python version managed by `uv` for the harness user (default: `"3.14"`).
- `nvm_node_version`: Node.js version to install (default: `"lts/*"`).
- `ollama_enabled`: Set to `false` if using an external inference server (default: `true`).
- `ollama_models`: List of models to pull automatically (e.g. `["kimi-k2.7-code:cloud", "qwen3-embedding:0.6b"]`).
- `ollama_signin_required`: Set to `true` if pulling Ollama Cloud models requiring interactive OAuth browser login (default: `false`).
- `essential_packages_extra`: Additional custom system packages to install (e.g. `["zsh", "fish"]`).
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
- Install hypervisor integration (`qemu-guest-agent`).
- Apply full system security hardening (SSH keys only, Fail2ban, unattended-upgrades, sysctl, core dumps disable, umask 027, anti-DoS limits).
- Install essential developer tools (`ripgrep`, `fd`, `btop`, `nvtop`, etc.).
- Create the dedicated agent user (`0750`) with scoped sudo permissions and systemd lingering.
- Install Podman Rootless with Docker/Compose compatibility layer and Google gVisor (`runsc`) as default runtime.
- Configure UFW firewall, Node.js via NVM, and **`uv` with Python 3.14**.
- Install Ollama (bound strictly to `127.0.0.1`) and pull configured models (if enabled).
- Reboot the machine automatically only if pending kernel updates require it.

### Step 3: Connect & Launch Agent

Connect directly as the dedicated agent user:

```bash
ssh <harness_name>@<VM_IP_ADDRESS>
# Example: ssh hermes@10.0.0.1
```

---

## 🔒 Security Architecture

```
┌────────────────────────────────────────────────────────┐
│  Proxmox VE Hypervisor (QEMU Guest Agent + KVM)       │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Dedicated VM (UFW + Fail2ban + Auto-Upgrades)    │  │
│  │  ┌────────────────────────────────────────────┐  │  │
│  │  │  Non-Root Harness User (e.g. hermes 0750)  │  │  │
│  │  │  • Scoped Sudoers: restart only            │  │  │
│  │  │  • Anti-DoS Limits: nproc 2048 / nofile    │  │  │
│  │  │  • Podman Rootless (User Namespaces)       │  │  │
│  │  │  • Docker & Compose CLI Compatibility      │  │  │
│  │  │  • Python 3.14 via uv + Node.js via NVM   │  │  │
│  │  │  ┌──────────────────────────────────────┐  │  │  │
│  │  │  │  gVisor Sandbox (runsc User-Kernel)  │  │  │  │
│  │  │  │  Default Runtime for all Containers  │  │  │  │
│  │  │  └──────────────────────────────────────┘  │  │  │
│  │  └────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────┘
```

- **Scoped Sudoers**: The agent user can only restart its own service (`sudo systemctl restart <harness_name>`). Stopping the service or reading system logs (`journalctl`) is strictly prohibited.
- **Rootless User Namespaces**: The agent process cannot escape container boundaries to gain root privileges on the host VM.
- **gVisor by Default**: Any container invocation (`podman run`, `docker run`, `docker compose up`) automatically runs within a user-space kernel sandbox to neutralize host kernel 0-day exploits.
- **Kernel & Memory Hardening**: Core dumps disabled, kernel pointers masked (`kptr_restrict`), dmesg restricted to root, obsolete network modules blacklisted.

---

## 🙌 Acknowledgments

Inspired by the [openclaw-ansible](https://github.com/openclaw/openclaw-ansible/) repository.
