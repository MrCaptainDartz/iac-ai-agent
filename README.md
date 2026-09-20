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
     - **Git Broker (loopback, propose-only)**: An SSH front that terminates the session in the trust zone and re-originates it with the deployment key — no proxy can inject anything into an encrypted channel, and the agent holds only a key that opens the relay. Pull requests and LFS go through the token injection proxy, which replaces whatever credential the agent sent with the one it holds. The forge's branch protection is the control that bounds it — and the proxy refuses the merge route itself unless a deployment opens it, per repository.
     - **Trust Zone**: A dedicated system user for every component holding a secret (the gateway, the L7 proxy and both brokers). It never executes model-produced code, and the agent cannot read its config or secrets.
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
- `security_hardening_fail2ban_ignoreip`: Sources fail2ban never bans (default: `127.0.0.1/8 ::1`). The SSH jail runs in aggressive mode, where a connection that never authenticated already counts as a failure — declare your control node and admin workstations here, or a play can lose access for an hour mid-run.
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
- `git_broker_enabled`: Deploy the git broker — branches, push and pull requests from the agent zone, over the forge's own SSH transport (default: `false`). Requires the trust zone, a deployment key and the forge's host key — see step 5 below.
- `git_broker_ssh_port`: Loopback port of the SSH front (default: `2222`).
- `git_broker_forge_ssh_user` / `git_broker_forge_ssh_host` / `git_broker_forge_ssh_port`: **Required when enabled** (the user has a default of `git`) — the forge's SSH endpoint, the same shape on Forgejo, GitLab and GitHub.
- `git_broker_repos`: **Required when enabled** — the repositories the agent may reach, as the forge names them (`["owner/repo.git"]`).
- `git_broker_forge_host_key`: **Required when enabled** — the forge's own `known_hosts` line, pinned: `ssh-keyscan -p <port> <host>`.
- `git_broker_ssh_key_src`: path on the control node to the deployment key — a secret, so a file and not a variable. The play **creates** it when it is absent, under `output/` (gitignored, with its public half beside it), and stops so you can register that half; point this at a file of your own (under `files/`) to supply the key instead.
- `git_broker_api_upstream` / `git_broker_api_repo_prefix` / `git_broker_api_auth_header`: the HTTP half — the forge's API base URL (`https://git.example.com`, or `https://api.github.com`) — the **name** the front answers under, not its address, since that is what it routes on, the path prefix that names one repository (`/api/v1/repos/` on Forgejo, `/repos/` on GitHub, `/api/v4/projects/` on GitLab), and the header the proxy injects. The routed paths are **derived from `git_broker_repos`**: the agent reads the repositories it declares — everything the forge exposes under that prefix, CI job logs and hook configuration included, which is a widening over what it already reads by git — and proposes on their pull requests and issues (`/pulls`, `/issues`); nothing else of the account's API is routed. Each declared path is **bounded**: the proxy admits that path exactly and its subtree, never a longer name that merely starts with it, so `owner/repo` does not open `owner/repo-backend`. Override `git_broker_api_read_locations` and `git_broker_api_proposal_locations` for a forge that names them differently.
- `git_broker_api_read_methods` / `git_broker_api_proposal_methods`: the verbs that reach those paths (defaults: `['GET']` and `['GET', 'POST', 'PATCH']`). Reading is `GET`/`HEAD`; proposing is `POST`, plus `PATCH` if the agent may edit or close a pull request — a human's as well, the forge having no per-object permission, which is why it is the first widening to drop. Nothing else is routed, so deleting a repository or writing its settings has no door here.
- `git_broker_allow_merge`: whether the agent may **merge** a pull request (default: `false`). Opening a proposal is not landing it: the proxy refuses `POST …/pulls/N/merge` with a regex location, which wins over the prefix that admits the `POST`, so PR creation is untouched. On GitHub and GitLab the merge is a `PUT`, already outside the declared verbs — this flag opens nothing there.
- `git_broker_merge_whitelist`: which repositories `git_broker_allow_merge` admits, as `git_broker_repos` names them. Empty or `['*']` means every declared repository; otherwise only the ones listed are mergeable. An entry that is neither `*` nor a declared repository fails the play, rather than building a guard that would never match.
- `git_broker_merge_allowed` / `git_broker_merge_refused`: derived — the repositories the flag admits, and one regex per refused repository, carried by the proposal entry as `refused_paths` (a field the injection proxy knows nothing about: it renders a `location ~ … { return 403; }` per pattern, at the head of the block).
- `git_broker_api_probe`: derived — a `GET` on the first declared repository, which answers 200 only for a token allowed to read it. It is a **request path**, where a location is a **match pattern**: a forge that wants its repository path encoded wants that encoding *here*, while the location stays in its normalised form. On GitLab, for instance, the read location is `/api/v4/projects/group/project` and the probe `/api/v4/projects/group%2Fproject` — and GitLab serves merge requests on `/merge_requests` rather than `/pulls`, so `git_broker_api_proposal_locations` needs the same override; without it the agent's `POST` simply 404s, fail-closed.
- `git_broker_api_ca_src`: **Required for a self-signed front** — path on the control node to the authority that signed its certificate (the file may hold the chain: the authority and any intermediate). That certificate must carry the name in `git_broker_api_upstream`: nginx verifies the name it connects under, and its own error says so when they differ. Nothing has to be added to the VM's trust store — the agent only ever speaks HTTP to the loopback. Upstream TLS is verified either way, against this authority or against `token_proxy_ca_bundle`.
- `git_broker_lfs_enabled`: Serve LFS through the same proxy (default: `true`); `git_broker_lfs_basic_user` names the account whose token goes into the `Basic` header LFS expects, and `git_broker_lfs_upstream` (default: the API upstream) is the host that serves the objects — GitHub's is `https://github.com`, not `https://api.github.com`. The links the forge builds carry back **that host's name**, which is what the agent's `.gitconfig` rewrites to the loopback; a forge whose public name is a third one (an internal upstream, a `ROOT_URL` elsewhere) adds it to `git_broker_lfs_rewrite_extra`. `git_broker_lfs_deployed` (derived) is the predicate the relay and the injection both test, so the endpoint is never handed out when LFS is off.
- `git_broker_token_src`: **Required for the HTTP half** — path on the control node to the forge token. A secret, so a file and not a variable: one line, and the proxy escapes it for nginx (a quote or a backslash in it travels whole, which it would not otherwise). The one character it cannot carry is `$`, which nginx reads as a variable and offers no escape for.
- `token_proxy_enabled`: Deploy the token injection proxy, the primitive a broker declares its endpoints into (default: `false`). Required by `git_broker`'s HTTP half: loopback only, under the trust-zone user, and the agent never holds the credential it injects. Every upstream must be `https://` — a plain one would put the injected credential on the wire and turn the certificate check into a no-op — and a **bare origin**: as soon as it carries a path, even a lone trailing slash, nginx rewrites the forwarded path, which hands the agent every path of that origin under the injected credential. The paths belong in the locations, not in the upstream. An entry may also carry `refused_paths` — regexes refused with a 403 at the boundary, which is how the git broker closes the merge route. Its access trail goes to the journal (`journalctl -u token-proxy`), where journald bounds it: the agent drives that volume, so it must not be a file it can grow.
- `token_proxy_port`: Loopback port the token proxy listens on (default: `8002`).
- `token_proxy_ca_bundle`: the trusted bundle nginx verifies the upstream against when an entry declares no `ca_src` (default: the system's `ca-certificates`).
- `essential_packages_extra`: Additional custom system packages to install (e.g. `["zsh", "fish"]`).
- `system_timezone_value`: Timezone (default: `"Europe/Paris"`).
- `system_reboot_on_kernel_update`: Reboot at the end of the play when a kernel update is pending (default: `true`). Set it to `false` on a VM that does not survive its own reboots — the play then finishes on the running kernel instead of waiting for a machine that never comes back.

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

### 5. Git Broker (optional)

Off by default. It answers what the read-only broker cannot: **proposing a change**. In GitOps a branch deploys nothing — the damage needs a merge, and the merge is a human gesture — so the agent's power is bounded by the forge's branch protection rather than by the broker. The proxy closes the merge route itself (`git_broker_allow_merge`, off by default), so that invariant no longer rests on a forge setting alone.

Two credentials are at play, and they are not the same kind of thing: the **deployment key** carries the git transport (a deploy key is scoped to one repository, which a personal access token is not), and the **account token** carries the HTTP half — pull requests and LFS. Both stay in the trust zone; the agent zone gets addresses and a placeholder key that opens nothing but the relay.

**On the forge** — and **not with your own account**: the token carries its holder's authority, so a personal one hands the broker's compromise everything you can do and blurs the forge's audit. A dedicated account, with:

- access to the targeted repository only, as a collaborator with **Write** — LFS uploads and pull requests both need it;
- a **write deploy key** on that repository (the transport), or the account's own SSH key;
- a **personal access token** for the API and LFS. Forgejo offers *Specific repositories* on its token page: use it and select just that repository, with the scopes `write:repository` (read, pull requests, LFS) and, only if the agent may also open or comment on issues, `write:issue`. Set an expiry: when it lapses the HTTP half stops — the play says so at its next run — while the git transport keeps working;
- **branch protection**, which is the control that counts: restrict push to a whitelist of humans (`enable_push` + `enable_push_whitelist`), forbid force-push, protect tags, leave `push_whitelist_deploy_keys` off, and — the merge being a second door to the same place — set the *merge* allowlist (`enable_merge` + `enable_merge_whitelist`) the same way. Neither the agent's key nor the account may be on either whitelist; the proxy already refuses merges by default, this is what bounds a merge performed by a *human* account;
- **the workflow paths**, for the same reason: a branch is not protected on arrival, so a modification of `.forgejo/workflows/` in a pushed branch runs the forge's runner — a machine outside this sandbox, with its own egress and, often, repository secrets. Protect those paths as you protect `main`, or keep secrets out of runs an unlisted actor can trigger. This is the escalation the push verb buys, and it is the forge's to close;
- **LFS**, if your repositories use it: enabling it on the forge is all there is to do — the broker serves it through the same proxy, and the client is already installed in the agent zone by the socle.

**And on this machine**: it must reach the forge's SSH port and its HTTPS endpoint, and it must **resolve the forge's name**. A public resolver knows nothing of an internal domain, so the deployment's own DNS has to be declared at provisioning time (`dns_servers`, `iac/`) — the proxy resolves its upstream when it loads its configuration, and refuses to start on a name it cannot resolve. The play checks both before it touches anything.

**Then produce the files** the play consumes. The **deployment key creates itself**: the first run generates it, writes its public half to `output/`, tells you what to register and stops there — before it would lift the agent zone's egress filter for a broker the forge does not know yet.

```bash
ansible-playbook -i inventory/inventory.yml playbook.yml   # 1. creates the key, stops: register
                                                          #    output/git-broker.key.pub as a
                                                          #    WRITE deploy key, then run it again
printf '%s\n' '<the account token>' > ansible/files/git-broker.token
ssh-keyscan -p 22 <forge-host>                                             # keep the wanted line as git_broker_forge_host_key
scp <forge>:/path/to/authority.pem ansible/files/forge-ca.pem              # a self-signed front: git_broker_api_ca_src
```

`ssh-keygen -l -f output/git-broker.key.pub` gives that key's fingerprint, to compare with the one the forge shows once it is registered. `files/` holds what *you* deposit — the token, the authority — and `output/` what the play *produces*: the generated key and its public half. Both stay out of the repository.

**From the agent zone**, the git transport is the forge's own, re-originated locally:

```bash
git clone ssh://git-broker/owner/repo.git      # an ~/.ssh/config alias to 127.0.0.1:2222
git checkout -b fix/whatever && git commit -am "…" && git push -u origin fix/whatever
curl -X POST http://127.0.0.1:8002/api/v1/repos/owner/repo/pulls -d '{…}'
```

Nothing else is handed over: no usable key, no token, no credential helper — and no shell. The relay refuses everything that is not `git-upload-pack`, `git-receive-pack` or `git-lfs-authenticate` on a declared repository, logs each refusal, and **rebuilds** the upstream command from the repository it matched: the agent's own string is never replayed, and any word beyond the verb, the repository and the LFS operation is refused. Both forms of the URL work, with or without the `.git` suffix.

The HTTP door is bounded the same way. Each declared path is admitted **exactly** and with its subtree — so a repository whose name merely starts with a declared one is not routed — and the two escapes that could mean something else upstream are refused, because the location is chosen on the normalised path while the raw one is what travels: a double-encoded `%`, and an encoded `.`. `%2F` is **not** one of them — both sides read it as a separator, and GitLab requires it for its `NAMESPACE/PROJECT_PATH` — so a forge whose paths need an encoded slash still works, and a declared path is named in its normalised form. A verb the forge might honour from `X-HTTP-Method-Override` is stripped, since it is not the verb `limit_except` admitted — and so is the agent's own `Authorization` whenever the entry injects another header, since a forge that prefers `Authorization` (GitLab does, over `PRIVATE-TOKEN`) would otherwise authenticate with the placeholder instead of the token.

**LFS** travels through the same token proxy. git-lfs asks the SSH server where its endpoint is (`git-lfs-authenticate`), and the relay answers with the loopback address — an address, never a credential; the proxy then injects the `Basic` header LFS expects. Both HTTP entries present the **forge's own name**, which is what a name-routing front (Traefik, Caddy) answers — the agent's loopback name means nothing to a virtual host. Forgejo then builds its LFS links on that name (1.25.4 and later), and the agent's `.gitconfig` rewrites every base such a link can carry (the LFS upstream's own name, the loopback endpoint, the alias git-lfs would guess from the SSH remote) back to the proxy — so the object transfer keeps the injected credential without the agent ever holding one. When the forge hands its objects to an object store (S3, MinIO) the links point elsewhere and the agent zone cannot reach them — that is the egress proxy's business, not this broker's: declare the store in `agent_egress_proxy_allowlist`.

A container reaches both addresses only by sharing the host's network namespace, as for the Kubernetes broker.

Installing the proxy brings nginx's own unit, which listens on `:80`: the role stops, disables and **masks** it before starting its own instance under the trust-zone user — and the mask stays in place when the proxy is disabled, so a package upgrade cannot bring a public web server back on its own.

---

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
- Deploy the git broker, if the deployment declared one: a loopback SSH front that re-originates each session with the deployment key, and a token injection proxy carrying the forge's API and LFS — the agent zone is given addresses and a placeholder key (if enabled).
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
- **Agent Egress Filter (nftables, per uid)**: The agent user's outbound traffic is dropped outside the loopback, **name resolution included** — a DNS query is a full outbound path, with the query name as payload. Containers the agent launches are covered whichever network mode they use. Hooked at `output priority -50`, ahead of UFW's chain, so a UFW `accept` cannot override it; UFW keeps the ingress and its own output policy. This is the control that answers a manipulated model, which the hardening above does not. A play lifts the ruleset for the duration of a run — deployment needs the network the filter removes — and re-applies it last. Until it does, the agent zone is unfiltered, so the harness is stopped for the duration of a run once it is installed: an adversarial agent can watch for an open door, but it cannot use one it is not running behind. When the inference gateway is deployed, the provider's own loopback port is closed to the agent zone as well, so the gateway is the only path to a model. The host's own port **22** is closed to the agent zone by the same list: the loopback `sshd` is the machine's only pre-auth door to root, and nothing in the agent's workflow speaks SSH to the host — an operator still reaches it, the filter being per uid.
- **L7 Egress Proxy (loopback)**: The agent zone has no route off the machine, so a proxy on the loopback is the *only* way out — its allowlist is a hard control, not a convention, and a stopped proxy means no egress at all rather than a direct fallback. The proxy resolves the destination itself, so the agent needs no name resolution; it refuses internal destinations (RFC1918, loopback, link-local, CGNAT) so it cannot become a path to the LAN, and it logs one line per request — destination and decision — which is the artifact Phase 7 builds on. At level 2 the private CA key stays in the trust zone home (`0700`), and only the certificate is published to the system store.
- **Kubernetes Broker (loopback, read-only)**: The agent zone has no route to the cluster, so the broker is its only path, and the ServiceAccount token lives in the trust zone — the agent gets an address and a `token: ignore` placeholder. Read-only holds twice: the proxy refuses write methods and the `exec`/`attach`/`portforward`/`secrets`/`proxy` paths, and the token has no write verb either. The proxy's filter is best-effort (an encoded path can slip past it), which is why the ClusterRole is explicit rather than the built-in `view` — **the RBAC is the control that counts**. Reading the cluster is not the same as reading no secrets: pod environments, `kube-system` ConfigMaps and pod logs routinely carry tokens.
- **Git Broker (loopback)**: The agent can propose a change, never apply one — a branch deploys nothing, so the forge's branch protection is what bounds the power. The credential is injected at the boundary: the SSH session is terminated locally and re-originated in the trust zone with the deployment key (nothing can be injected into an encrypted channel), and the HTTP half goes through a reverse proxy that overwrites the agent's own `Authorization` header with the token it holds. Two new loopback doors (`2222`, `8002`), both deliberate; the relay refuses and logs anything that is not a declared git verb on a declared repository, and the proxy routes the API of the declared repositories only, with the declared verbs only — a token that could delete a repository has no path to the door that would. Merging is the one route it closes by name: a regex location refuses `POST …/pulls/N/merge` before the prefix that would admit it, unless a deployment opens it per repository.
- **Trust Zone & Inference Gateway (loopback)**: The harness reaches the model through a gateway bound to `127.0.0.1` and running as a **separate system user** — so the agent can neither stop it nor read its config, secrets or virtualenv. Provider keys live in a `0600` env file owned by that user and are referenced as `os.environ/...`, so they never appear in a config diff. The gateway's own files stay root-owned and group-readable: `ProtectSystem=strict` keeps them read-only for the service itself. The L7 proxy runs under the same user, and for the same reason: it holds the CA private key at level 2, and running a proxy under the harness uid would not work anyway — the uid filter would cut its own egress.

---

## 📋 Roadmap

This project is a generic, composable sandbox rather than a solution to one use case. The socle (**per-uid egress control** + **inference gateway**) is always deployed, the **L7 egress proxy** is the adaptation brick, the **brokers** (Kubernetes, git) are optional extensions, and the **harness is installed last**, once the sandbox is ready. The component model and the phase order are in [TODO.md](TODO.md) §2.

---

## 🙌 Acknowledgments

Inspired by the [openclaw-ansible](https://github.com/openclaw/openclaw-ansible/) repository.
