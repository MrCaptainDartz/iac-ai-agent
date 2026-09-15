# IAC AI Agent Deployer

Infrastructure as Code (IaC) solution to automatically provision and configure hardened Virtual Machines on a **Proxmox VE** cluster, tailored for hosting autonomous AI Agents (such as **Hermes**, **OpenClaw**, **Smolagents**, etc.) with rootless sandboxing via **Podman + Google gVisor (`runsc`)**, Docker/Compose compatibility layer, modern Python tooling via **`uv` (Python 3.14)**, QEMU Guest Agent integration, and LLM inference with **Ollama**, running either locally or against a remote provider — fronted by a loopback **inference gateway** that keeps provider keys and model names out of the agent's reach, by a loopback **L7 egress proxy** whose allowlist the deployment declares, and, for an agent that must observe a cluster, by a loopback **Kubernetes broker** that keeps the ServiceAccount token out of the agent zone.

---

## 🎯 Goal of the Project

1. **Infrastructure Provisioning (OpenTofu / Terraform)**: Automate the creation of one or multiple VMs on Proxmox VE (CPU, RAM, disks, network interfaces, and optional GPU/PCI passthrough) using Ubuntu Cloud-Init images with native `qemu-guest-agent` support.
2. **Hardened Environment Configuration (Ansible)**:
   - **Harness-Agnostic Setup**: Configurable agent harness name (`harness_name: "hermes"` or `"openclaw"`).
   - **Least-Privilege Security**: Dedicated non-root user with `0750` home directory permissions and scoped sudo permissions (`restart` only) to prevent privilege escalation, denial of service, and credential dumping.
   - **Continuous Operation**: `systemd` lingering enabled (`loginctl enable-linger`) with D-Bus/XDG user session for 24/7 background agent daemons.
   - **Kernel-Isolated Sandboxing ("Secure by Default")**: Rootless **Podman** container engine configured with Google **gVisor (`runsc`) as the default runtime**. Every container (`podman run`, `docker run`, `docker compose up`) automatically runs in a memory-safe user-space kernel sandbox. The runtime is deployed through a wrapper that can also carry gVisor's own `--network=host`: Podman's `--network=host` and gVisor's are two independent settings, and with Podman's alone the sandbox gets no interface at all.
   - **Full Docker & Compose Compatibility**: Drop-in `docker`, `docker-compose`, and `docker compose` compatibility via `podman-docker` and `podman-compose` with `DOCKER_HOST` socket integration.
   - **Multi-Layer Defense in Depth**:
     - **SSH Hardening**: Password authentication disabled, root login disabled, `AllowUsers` whitelist, rate-limiting, brute-force protection with **Fail2ban**, and Post-Quantum cryptography (`sntrup761x25519`).
     - **Resource Limits & Anti-DoS**: `limits.d` protection against fork bombs (`nproc 2048`), file descriptor exhaustion (`nofile 65536`), and core dump suppression.
     - **OS & Kernel Hardening**: `sysctl` kernel protections, memory sandbox (`yama.ptrace_scope = 1`), AppArmor enforce mode, `libpam-pwquality`, obsolete kernel modules blacklisting (`dccp`, `sctp`, `firewire`), and secure default `umask 027`.
     - **Automated Security Updates**: `unattended-upgrades` with `apt-daily.timer` and automatic kernel cleanups.
     - **Ollama Security**: Explicit localhost binding (`127.0.0.1:11434`) via systemd override — this closes the **inbound** path, so the endpoint is not reachable from the network. It does not constrain **outbound** traffic: a model backed by a remote provider still generates egress, which the agent egress filter governs separately (see below).
     - **Inference Gateway (loopback, alias table)**: The harness asks for a **role alias** (`reasoning`, `execution`), never for a provider model, so its own configuration survives a provider change. The provider's port is closed to the agent zone, so the alias table cannot be bypassed.
     - **L7 Egress Proxy (loopback, allowlist)**: When a deployment needs web egress, this is the agent zone's **only** way out — an explicit forward proxy whose allowlist is declared per deployment (`[.]host[:port][/path]`), refusing internal destinations. Level 1 (default) filters on destination with **no CA to distribute**; level 2 (opt-in) adds TLS interception, which buys path rules and per-request visibility at the cost of distributing an internal CA.
     - **Kubernetes Broker (loopback, read-only)**: For an SRE agent, `kubectl proxy` under the trust-zone user, reading a read-only ServiceAccount's kubeconfig that never enters the agent zone. Write methods and the `exec`/`attach`/`portforward`/`secrets` paths are refused by the proxy, and the token has no write verb either — the RBAC is the layer that counts.
     - **Trust Zone**: A dedicated system user for every component holding a secret (the gateway, the L7 proxy and the Kubernetes broker today, the git broker later). It never executes model-produced code, and the agent cannot read its config or secrets.
   - **Modern Python & Developer Stack**: **`uv`** standalone manager with **Python 3.14**, Node.js (via NVM), global Git & Vim configurations, essential search & monitoring tools (`ripgrep`, `fd-find`, `btop`, `nvtop`), UFW firewall, and Ollama with automated model downloading.

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
- `harness_ssh_keys`: Optional additional SSH public keys for the harness user (default: `[]`).
- `ssh_allow_tcp_forwarding`: Set to `true` if SSH port forwarding/tunneling is needed (default: `false`).
- `gvisor_enabled`: Enable Google gVisor (`runsc`) runtime in Podman (default: `true`).
- `gvisor_default`: Use gVisor (`runsc`) as the default OCI runtime for all containers (default: `true`).
- `podman_gvisor_netns`: Default network mode for **every** container, in Podman's own vocabulary (default: `""`, i.e. Podman's own choice). `host` shares the host's network namespace with every container the agent launches.
- `podman_gvisor_hostinet`: Give **every** container gVisor's host stack instead of its netstack (default: `false`). Required for `--network=host` to work at all under rootless Podman; the narrower way is `--runtime-flag network=host` on the one container that needs the host's loopback.
- `uv_python_version`: Python version managed by `uv` for the harness user (default: `"3.14"`).
- `nvm_node_version`: Node.js version to install (default: `"lts/*"`).
- `ollama_enabled`: Set to `false` if using an external inference server (default: `true`).
- `ollama_models`: List of models to pull automatically (e.g. `["qwen3:4b", "qwen3-embedding:0.6b"]`). The shipped default is a small local model; remote models are a deployment choice — declare them here and set `ollama_signin_required: true` if the provider needs an interactive login.
- `ollama_signin_required`: Set to `true` if pulling models that require an interactive OAuth browser login (default: `false`).
- `agent_egress_filter_enabled`: Filter the agent user's outbound traffic by uid — loopback only, name resolution included (default: `true`). Set to `false` to leave the outbound path unrestricted; table, unit and ruleset file are then removed.
- `trust_zone_enabled`: Create the trust-zone system user (default: `true`). Set to `false` to remove it; do so only once no component depends on it.
- `broker_name`: Name of the trust-zone system user (default: `"broker"`).
- `inference_gateway_enabled`: Deploy the loopback inference gateway (default: `true`). `false` removes the unit, config and virtualenv, and reopens the provider's port to the agent zone.
- `inference_gateway_port`: Loopback port the gateway listens on (default: `4000`).
- `inference_gateway_upstream_url`: Local provider endpoint (default: `http://127.0.0.1:11434`). Used as the aliases' default `api_base`, and its port is closed to the agent zone.
- `inference_gateway_models`: **Required** alias table — the alias the agent sees, mapped to the real provider model. The provider prefix picks the upstream endpoint (`ollama_chat/` for chat with tool calling, `ollama/` for embeddings); `api_base` defaults to the upstream URL for local models only, so a remote entry keeps its provider's own endpoint unless it declares one. A per-entry `api_key` is held by the gateway, never by the harness.
- `inference_gateway_debug_logging`: litellm's detailed debug stream, prompts included (default: `false`). It is a debugging aid, not an audit trail.
- `agent_egress_proxy_enabled`: Deploy the L7 egress proxy — the agent zone's only way out (default: `false`). `false` leaves the agent zone with no web egress at all, which is the socle.
- `agent_egress_proxy_port`: Loopback port the proxy listens on (default: `8080`).
- `agent_egress_proxy_allowlist`: **Required when enabled** — `[.]host[:port][/path]` entries; a leading dot covers subdomains, no port means 80 and 443, and a path prefix requires TLS interception. An entry `"*"` — quoted, since YAML reads a bare `*` as an alias — allows any public host: the whole internet, internal destinations excepted, at the cost of the destination control itself.
- `agent_egress_proxy_tls_intercept`: TLS interception with an internal CA (default: `false`). Level 2 unlocks path rules and per-request visibility, and costs the CA distributed to every client stack — clients that pin a certificate break.
- `k8s_broker_enabled`: Deploy the read-only Kubernetes broker, the agent zone's only path to a cluster (default: `false`). Requires the trust zone and a ServiceAccount kubeconfig — see step 4 below.
- `k8s_broker_port`: Loopback port the broker listens on (default: `8001`).
- `k8s_broker_kubeconfig_src`: **Required when enabled** — path on the control node to the ServiceAccount kubeconfig. A secret, so a file and not a variable; the example points at `ansible/files/k8s-broker.kubeconfig`, which is gitignored.
- `essential_packages_extra`: Additional custom system packages to install (e.g. `["zsh", "fish"]`).
- `system_timezone_value`: Timezone (default: `"Europe/Paris"`).

### 4. Kubernetes Broker (optional)

Off by default. The half that belongs to the cluster is **not** deployed by this repository: the VM must not be a cluster node (a node's own kubeconfig is cluster-admin), and the deployment has no reason to leave a cluster-admin kubeconfig on the control node.

Two identities are at play and they are unrelated: the **trust zone** is a Linux user local to the VM, the **ServiceAccount** is an identity the cluster's API server recognises — and the broker holds both. An external secret manager (ESO, a Vault, an OpenBao) is a separate plane: the broker never talks to it, and reading an `ExternalSecret` yields a store path and a sync status, never a value.

**On the cluster** — apply `ansible/roles/k8s_broker/files/k8s-broker-rbac.yaml` (adjust the namespace and the names if you like). It creates a ServiceAccount with an **explicit** ClusterRole — `get`/`list`/`watch` only, no secrets, no `pods/exec`, no `impersonate`, no write verb — and the long-lived token Secret it authenticates with. Check what it really grants:

```bash
kubectl auth can-i --list --as=system:serviceaccount:sre-agent:sre-readonly
```

**Then build the kubeconfig** the play consumes, with cluster-admin rights on the control node:

```bash
NS=sre-agent; SA=sre-readonly
TOKEN=$(kubectl -n $NS get secret $SA-token -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl -n $NS get secret $SA-token -o jsonpath='{.data.ca\.crt}')
kubectl config set-cluster broker --server=https://<api-server>:6443 \
  --certificate-authority-data="$CA" --kubeconfig=ansible/files/k8s-broker.kubeconfig
kubectl config set-credentials $SA --token="$TOKEN" --kubeconfig=ansible/files/k8s-broker.kubeconfig
kubectl config set-context $SA --cluster=broker --user=$SA --kubeconfig=ansible/files/k8s-broker.kubeconfig
kubectl config use-context $SA --kubeconfig=ansible/files/k8s-broker.kubeconfig
```

**From the agent zone**, the cluster is at `http://127.0.0.1:8001`, and the role writes the matching kubeconfig to `/home/<harness>/.kube/config` with a `token: ignore` placeholder — an address, never a credential. A container only reaches it by sharing the host's network namespace (`--network=host`), alongside gVisor's own `--network=host` on a deployment that left `podman_gvisor_hostinet` off. A container with its own network namespace sees `127.0.0.1` as its own loopback and gets nowhere either way.

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
- Apply full system security hardening (SSH keys only, Post-quantum crypto, Fail2ban, unattended-upgrades, sysctl, core dumps disable, umask 027, anti-DoS limits, AppArmor, pwquality).
- Install essential developer tools (`ripgrep`, `fd`, `btop`, `nvtop`, etc.) and deploy global Git/Vim configurations.
- Create the dedicated agent user (`0750`) with scoped sudo permissions and systemd lingering.
- Install Podman Rootless with Docker/Compose compatibility layer and Google gVisor (`runsc`) as default runtime.
- Configure UFW firewall, Node.js via NVM, and **`uv` with Python 3.14**.
- Install Ollama (bound strictly to `127.0.0.1:11434`) and pull configured models (if enabled).
- Create the trust-zone user, then deploy the inference gateway: a loopback front door whose alias table maps the roles the agent asks for onto real provider models (if enabled).
- Deploy the L7 egress proxy, if the deployment declared one: the agent zone's only way out, under an allowlist, with the internal CA distributed when TLS interception is on (if enabled).
- Deploy the Kubernetes broker, if the deployment declared one: a loopback `kubectl proxy` under a read-only ServiceAccount, and the agent zone is given the broker's address, never its token (if enabled).
- **Lock the sandbox down last**: filter the agent user's outbound traffic by uid — loopback only, name resolution included — leaving a manipulated model with no route off the machine.
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
│  ┌────────────────────────────────────────────────────────┐
  │  Proxmox VE Hypervisor (QEMU Guest Agent + KVM)        │
  │  ┌──────────────────────────────────────────────────┐  │
  │  │  Dedicated VM (UFW + Fail2ban + Auto-Upgrades)   │  │
  │  │  ┌────────────────────────────────────────────┐  │  │
  │  │  │  Non-Root Harness User (e.g. hermes 0750)  │  │  │
  │  │  │  • Scoped Sudoers: restart only            │  │  │
  │  │  │  • Anti-DoS Limits: nproc 2048 / nofile    │  │  │
  │  │  │  • Harness runs bare, outside gVisor       │  │  │
  │  │  │  • Podman Rootless + Docker/Compose layer  │  │  │
  │  │  │  • Python 3.14 via uv + Node.js via NVM    │  │  │
  │  │  │  ┌──────────────────────────────────────┐  │  │  │
  │  │  │  │  gVisor Sandbox (runsc user-kernel)  │  │  │  │
  │  │  │  │  Containers the agent launches only  │  │  │  │
  │  │  │  └──────────────────────────────────────┘  │  │  │
  │  │  └────────────────────────────────────────────┘  │  │
  │  └──────────────────────────────────────────────────┘  │
  └────────────────────────────────────────────────────────┘
```

- **Scoped Sudoers**: The agent user can only restart its own service (`sudo systemctl restart <harness_name>`). Stopping the service or reading system logs (`journalctl`) is strictly prohibited. The service unit itself is created when the harness is installed — until then this rule targets a unit that does not exist yet.
- **Rootless User Namespaces**: Containers launched by the agent cannot reach the host. The agent process itself is **not** containerized: it runs bare on the VM.
- **gVisor by Default**: Any container invocation (`podman run`, `docker run`, `docker compose up`) automatically runs within a user-space kernel sandbox to neutralize host kernel 0-day exploits. This confines **the containers the agent launches** — not the agent.
- **Kernel & Memory Hardening**: Core dumps disabled, kernel pointers masked (`kptr_restrict`), dmesg restricted to root, obsolete network modules blacklisted.
- **Agent Egress Filter (nftables, per uid)**: The agent user's outbound traffic is dropped outside the loopback, **name resolution included** — a DNS query is a full outbound path, with the query name as payload. Containers the agent launches are covered whichever network mode they use. Hooked at `output priority -50`, ahead of UFW's chain, so a UFW `accept` cannot override it; UFW keeps the ingress and its own output policy. This is the control that answers a manipulated model, which the hardening above does not. When the inference gateway is deployed, the provider's own loopback port is closed to the agent zone as well, so the gateway is the only path to a model.
- **L7 Egress Proxy (loopback)**: The agent zone has no route off the machine, so a proxy on the loopback is the *only* way out — its allowlist is a hard control, not a convention, and a stopped proxy means no egress at all rather than a direct fallback. The proxy resolves the destination itself, so the agent needs no name resolution; it refuses internal destinations (RFC1918, loopback, link-local, CGNAT) so it cannot become a path to the LAN, and it logs one line per request — destination and decision — which is the artifact Phase 7 builds on. At level 2 the private CA key stays in the trust zone home (`0700`), and only the certificate is published to the system store.
- **Kubernetes Broker (loopback, read-only)**: The agent zone has no route to the cluster, so the broker is its only path, and the ServiceAccount token lives in the trust zone — the agent gets an address and a `token: ignore` placeholder. Read-only holds twice: the proxy refuses write methods and the `exec`/`attach`/`portforward`/`secrets`/`proxy` paths, and the token has no write verb either. The proxy's filter is best-effort (an encoded path can slip past it), which is why the ClusterRole is explicit rather than the built-in `view` — **the RBAC is the control that counts**. Reading the cluster is not the same as reading no secrets: pod environments, `kube-system` ConfigMaps and pod logs routinely carry tokens.
- **Trust Zone & Inference Gateway (loopback)**: The harness reaches the model through a gateway bound to `127.0.0.1` and running as a **separate system user** — so the agent can neither stop it nor read its config, secrets or virtualenv. Provider keys live in a `0600` env file owned by that user and are referenced as `os.environ/...`, so they never appear in a config diff. The gateway's own files stay root-owned and group-readable: `ProtectSystem=strict` keeps them read-only for the service itself. The L7 proxy runs under the same user, and for the same reason: it holds the CA private key at level 2, and running a proxy under the harness uid would not work anyway — the uid filter would cut its own egress.

---

## 📋 Roadmap

This project is a generic, composable sandbox rather than a solution to one use case. The socle (**per-uid egress control** + **inference gateway**) is always deployed, the **L7 egress proxy** is the adaptation brick, the **brokers** (Kubernetes, git) are optional extensions, and the **harness is installed last**, once the sandbox is ready. The component model and the phase order are in [TODO.md](TODO.md) §2.

---

## 🙌 Acknowledgments

Inspired by the [openclaw-ansible](https://github.com/openclaw/openclaw-ansible/) repository.
