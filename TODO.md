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

> **Le projet livre des implémentations, pas seulement des abstractions.** Exactement comme `ollama` est *une* implémentation possible de l'inférence (`inference_provider`), le projet **livrera un** provider d'installation de harnais (`harness_provider: hermes`), à créer en Phase 8. C'est une commodité assumée, pas une entorse au principe : le socle reste agnostique, et supporter un autre harnais consiste à ajouter un rôle provider — le chemin prévu, documenté en Phase 8.

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

---

## 🏗️ 1. État déployé

Le socle d'isolation multi-couches est en place. **« Déployé » ne veut pas dire « vérifié »** : aucun contrôle automatisé n'atteste l'état réel aujourd'hui — c'est l'objet de la Phase 7.

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
│  │   • Aucun credential (cible) · egress via proxy L7 (cible)             │  │
│  │   ┌───────────────────────────────────────────────────────────────┐   │  │
│  │   │  gVisor (runsc) — runtime OCI par défaut                       │   │  │
│  │   │  Sandbox des conteneurs LANCÉS PAR l'agent, pas de l'agent     │   │  │
│  │   └───────────────────────────────────────────────────────────────┘   │  │
│  │                                                                        │  │
│  │   ZONE DE CONFIANCE — OPTIONNELLE   uid={{ broker_name }}              │  │
│  │   Déployée seulement si un composant détient un secret.                │  │
│  │   • Gateway d'inférence  → provider, clé injectée (Phase 2)            │  │
│  │   • Proxy egress L7      → internet, allowlist (Phase 3)               │  │
│  │   • Broker Kubernetes    → kube-apiserver, jeton RO injecté (Phase 4)  │  │
│  │   • Broker git           → forge, token injecté (Phase 5)              │  │
│  │   N'exécute jamais de code du modèle.                                  │  │
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

---

## 🧩 2. Modèle de composants

Chaque composant est un rôle activable, dans le style existant.

| Composant | Rôle | Flag | Requis |
|---|---|---|---|
| Contrôle de l'egress par uid | `agent_egress` | `agent_egress_enabled` | **Socle** |
| Gateway d'inférence | `inference_gateway` | `inference_gateway_enabled` | **Socle** |
| Provider d'inférence local (Ollama) | `ollama` *(existant)* | `ollama_enabled` | Optionnel |
| Proxy egress L7 (niveau 1 : allowlist) | `egress_proxy` | `agent_egress_proxy_enabled` | Brique d'adaptation |
| Inspection TLS (niveau 2) | `egress_proxy` *(même rôle)* | `agent_egress_proxy_tls_intercept` | Opt-in |
| Broker Kubernetes (lecture seule) | `k8s_broker` | `k8s_broker_enabled` | Extension |
| Broker git (propositions de PR) | `git_broker` | `git_broker_enabled` | Extension |
| Installation du harnais (provider livré) | `harness_hermes` | `harness_provider: hermes` | Phase 8, **à créer** |
| Sécurisation du harnais (unité systemd) | `harness_service` | `harness_service_enabled` | Phase 8 |
| Zone de confiance (utilisateur système) | dépendance des brokers, du proxy en niveau 2, et du gateway s'il détient une clé | — | Créée à la demande |

**Exemples d'assemblages visés :**

- *Agent conversationnel* : zone agent + conteneurs + gateway d'inférence. Pas de zone de confiance si le provider est local et sans clé.
- *Agent avec navigation web* : socle + proxy L7 niveau 1, allowlist déclarée par le déploiement.
- *Agent SRE k3s* : socle + `k8s_broker` + `git_broker`.
- *Agent avec API d'inférence distante* : socle + gateway qui détient la clé (donc zone de confiance).

### Variables (conventions existantes)

```yaml
# --- Harnais (existant, agnostique) ---
harness_name: "hermes"              # hermes, openclaw, smolagents, ...
# L'entrypoint est la seule chose à renseigner côté harnais (Phase 8) :
# harness_exec_start: "/usr/local/bin/uv run python main.py"

# --- Socle ---
agent_egress_enabled: true          # filtrage de l'egress par uid

# --- Inférence : le provider est un choix de l'utilisateur ---
inference_gateway_enabled: true
inference_provider: "ollama"        # "ollama" (local) ou "external" (API distante)
inference_upstream_url: "http://127.0.0.1:11434"
# Pour un provider distant, la clé vit côté gateway, jamais côté harnais :
# inference_api_key: "{{ vault_inference_api_key }}"

# --- Proxy egress L7 (brique d'adaptation) ---
agent_egress_proxy_enabled: false       # false : la zone agent n'a aucun egress web
agent_egress_proxy_allowlist: []        # domaines autorisés, déclarés par déploiement
agent_egress_proxy_tls_intercept: false # niveau 2 : inspection (CA interne, opt-in)

# --- Extensions optionnelles ---
broker_name: "broker"               # utilisateur système de la zone de confiance
k8s_broker_enabled: false
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

#### 🌟 Phase 1 — Contrôle de l'egress par uid

L'allowlist devient **structurelle** (topologie) au lieu d'être content-based : si la zone agent n'a pas de route, il n'y a rien à filtrer au L7. C'est le socle sur lequel la Phase 3 vient se poser.

**Cette phase ne dépend que de l'uid du harnais**, qui existe déjà (`harness_user` est déployé). Elle est donc indépendante de l'installation du harnais et de son unité systemd (Phase 8), et c'est le seul contrôle vraiment bloquant pour le reste.

**Deux implémentations possibles — à trancher.** Les deux fonctionnent ; le choix porte sur la modularité.

**Option A (recommandée) : table nftables dédiée et optionnelle.** Auto-contenue, testable seule (`nft list ruleset`), ne dépend pas d'UFW — donc utilisable par quelqu'un qui n'utilise pas UFW. Ordre garanti par la priorité de hook.

```nft
table inet agent_egress {
  # Priorité NÉGATIVE : évalué avant la chaîne filter d'UFW (priorité 0),
  # sinon un `accept` d'UFW pourrait court-circuiter ces drop.
  chain output {
    type filter hook output priority -50; policy accept;

    # Zone agent : loopback uniquement. Couvre aussi les conteneurs gVisor,
    # car pasta/slirp4netns sort sous l'uid du harnais.
    meta skuid <uid_agent> ip daddr != 127.0.0.0/8 counter drop

    # Composants de la zone de confiance (si déployés) : uniquement leurs upstreams
    meta skuid <uid_broker> ip daddr { <upstreams...> } tcp dport 443 counter accept
    meta skuid <uid_broker> counter drop
  }
}
```

**Option B (minimale) : `/etc/ufw/before.rules`.** Suffit techniquement — les chaînes `ufw-before-*` sont traversées avant la politique de sortie par défaut, et `iptables-restore` accepte le match `owner` en OUTPUT :

```
-A ufw-before-output -m owner --uid-owner <uid_agent> ! -d 127.0.0.0/8 -j DROP
```

Évite un second outil, mais couple la politique à UFW et reste un fichier `iptables-restore` peu lisible.

- [ ] **Ne pas migrer UFW vers nftables intégralement.** UFW gère bien l'ingress, est déjà déployé, et fail2ban utilise son action `ufw`. Le remplacer imposerait de réimplémenter l'ingress et de casser l'intégration fail2ban. **UFW reste pour l'ingress, l'egress par uid s'ajoute à côté.**
- [ ] Utiliser les **uid numériques** dans la conf finale (le nom doit exister au chargement).
- [ ] `agent_egress_enabled: false` ne doit rien modifier d'autre.
- [ ] **Vérifier l'interaction UFW ↔ nftables empiriquement** : `sudo -u {{ harness_name }} curl -m3 https://example.com` doit timeouter, puis `nft list ruleset`.
- [ ] Prévoir les exceptions d'egress du **gateway d'inférence** (Phase 2) et du **proxy L7** (Phase 3) : leurs uid respectifs reçoivent l'accès sortant que la zone agent n'a pas.
- [ ] Noter que la couche systemd complémentaire (`IPAddressDeny`) arrive avec l'unité du harnais (Phase 8) — elle n'est pas nécessaire ici, le filtrage par uid suffit.

#### 🌟 Phase 2 — Gateway d'inférence

Composant qui rend le **provider d'inférence interchangeable** : Ollama local, API distante, ou autre. Sert aussi de point d'application pour les transformations de prompt.

- [ ] Reverse proxy loopback, **HTTP simple** : le provider est joignable en local (Ollama) ou le gateway fait lui-même le TLS amont. Pas de CA interne, pas de MITM.
- [ ] **Injection de la clé du provider** : si le provider en exige une, c'est le gateway qui la détient — jamais le harnais. C'est ce qui décide si le gateway rejoint la zone de confiance (règle du §0).
- [ ] **Ordre canonique du préfixe** pour les cache-hits : partie invariante (system prompt, tools, contexte) *octet pour octet identique* en tête, partie volatile en queue. Sérialisation déterministe : **aucun timestamp, UUID, ni ordre de dict non déterministe dans le préfixe**.
- [ ] Compression de la partie volatile (augmente le *ratio* de préfixe caché).
- [ ] Logs prompt/réponse (audit) et **quotas de tokens** — un agent en boucle peut épuiser un budget d'API.
- [ ] Allowlist de modèles, configurable. **Ne rien présupposer du provider** : les modèles distants et locaux doivent être également possibles.
- [ ] Le rôle `ollama` existant reste tel quel (optionnel, `ollama_enabled`) ; le gateway est une couche au-dessus, pas un remplacement.

### Brique d'adaptation

#### 🌟 Phase 3 — Proxy egress L7

**Pourquoi cette brique dans un projet générique.** On ne peut pas prédire ce dont chaque harnais a besoin. Un broker est spécifique à un cas d'usage (Kubernetes, git) ; un proxy à allowlist configurable est le primitif qui permet à **n'importe quel** déploiement de déclarer sa politique d'egress **sans écrire de code**. C'est ce qui rend le projet capable de protéger des cas d'agent hétérogènes.

**Deux niveaux, activables séparément** — parce que leur coût n'a rien à voir.

**Niveau 1 — allowlist de destinations, sans interception TLS** *(défaut quand la brique est activée)*

- Proxy *forward* explicite (CONNECT), allowlist par domaine et port.
- **Aucune CA interne, aucune distribution de certificat.** Le client est configuré pour utiliser le proxy (`HTTPS_PROXY`, config applicative du harnais).
- Filtrage au niveau **destination uniquement** : pas de visibilité sur les chemins ni les corps.
- **Fail-closed obligatoire** : la Phase 1 ne laisse la zone agent sortir que vers le port du proxy. Si le proxy tombe, les clients échouent — ils ne basculent **pas** en direct. C'est cette propriété qui rend un proxy configuré par variable d'environnement acceptable, alors qu'il serait trivialement contournable autrement.
- Le proxy ne détient **aucun secret** → il peut rester hors de la zone de confiance (règle du §0). Un déploiement sans broker n'a donc que ce composant à ajouter.

**Niveau 2 — inspection et injection (interception TLS)** *(opt-in)*

- MITM avec CA interne : visibilité sur les chemins, méthodes et corps. Débloque la politique par chemin, l'injection de credential pour un provider non couvert par un broker, et l'inspection de contenu.
- **Coût réel, à assumer explicitement** : la CA doit être déployée dans le trust store système **et** dans `certifi` (uv/Python), `NODE_EXTRA_CA_CERTS` (Node), la config git, et le kubeconfig. Les clients qui épinglent un certificat cassent.
- Le proxy détient alors la clé privée de la CA → **il rejoint la zone de confiance**.
- **Ne jamais router les jetons des brokers** (k8s, git) à travers ce proxy : ils ont leurs propres exceptions d'egress et leurs propres brokers. Le proxy sert l'egress web générique du harnais.

- [ ] **Un seul outil pour les deux niveaux** si possible, pour ne pas multiplier les composants : `mitmproxy` en mode *regular* couvre le niveau 1, le niveau 2 étant le même composant avec interception TLS + addons de politique. Alternative « boring » pour le niveau 1 : `Squid` ou `tinyproxy` (ACL par domaine, pas de MITM natif).
- [ ] **Refuser les destinations internes** (RFC1918, loopback, link-local) : sinon le proxy devient un chemin vers le LAN et défait la Phase 1.
- [ ] **Journaliser chaque requête** (destination, statut, taille) → principal artefact de détection d'exfiltration (Phase 7).
- [ ] Quotas / rate-limits par destination, pour borner un agent en boucle.
- [ ] `agent_egress_proxy_tls_intercept: false` par défaut, et la documentation doit dire ce que le niveau 2 coûte avant de l'activer.
- [ ] Mettre à jour la Phase 1 : l'uid du proxy reçoit l'unique exception d'egress web.

### Extensions optionnelles

> Chaque extension ajoute un broker à la zone de confiance. **Aucune n'est requise** : un agent purement conversationnel n'a besoin ni de l'une ni de l'autre.

#### 🌟 Phase 4 — Broker Kubernetes (lecture seule)

Cas d'usage : agent SRE. **Pas de MITM, pas de CA interne** — le harnais parle en HTTP clair à un port loopback, le broker fait le TLS en amont.

- [ ] Vérifier que la VM agent **n'est pas un nœud k3s** (le kubeconfig du serveur est cluster-admin ; les identifiants de nœud sont très privilégiés).
- [ ] ServiceAccount + ClusterRole **explicite** (ne pas utiliser le `view` intégré, contenu variable selon les versions) :

```yaml
kind: ClusterRole
metadata: { name: agent-diagnostics }
rules:
  - apiGroups: [""]
    resources: ["pods","services","endpoints","configmaps","nodes",
                "namespaces","events","persistentvolumeclaims"]
    verbs: ["get","list","watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: ["apps","batch","networking.k8s.io","apiextensions.k8s.io"]
    resources: ["*"]
    verbs: ["get","list","watch"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["*"]
    verbs: ["get","list"]
# NI secrets, NI pods/exec|portforward|attach, NI impersonate, aucun write.
```

- [ ] Vérifier : `kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa>`.
- [ ] Jeton : durée de vie configurable (longue en homelab, ou 15 min + timer + reload du proxy).
- [ ] Kubeconfig du broker en `0600`, **illisible par la zone agent**.
- [ ] Unité systemd `kubectl proxy` durcie :

```bash
kubectl proxy --port=<port> --address=127.0.0.1 \
  --reject-methods='POST,PUT,PATCH,DELETE' \
  --reject-paths='^/api/.*/secrets,^/apis/.*/secrets,^/api/.*/pods/.*/(exec|attach|portforward)'
```

  `--reject-paths` **remplace** les motifs par défaut (qui rejettent déjà `exec`/`attach`) → les inclure explicitement. Si un `403` sur le `Host` apparaît, ajouter `--accept-hosts='.*'` (le proxy n'écoute que sur loopback).
- [ ] Kubeconfig bidon côté zone agent : `server: http://127.0.0.1:<port>`, `token: ignore`.
- [ ] **Deux couches indépendantes** : `--reject-methods` rend le proxy read-only, le RBAC rend le jeton read-only. Le filtre regex est best-effort : **le RBAC est le contrôle réel.**

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
- [ ] Les `pip install` / `npm install` sont un point d'entrée pour un agent injecté : au minimum les journaliser, idéalement les restreindre à un miroir.

#### 🌟 Phase 7 — Observabilité & vérifications

À faire **avant** d'installer le harnais (Phase 8) : rien ne doit tourner sans être audité.

- [ ] Règles auditd `execve` sur l'uid du harnais : rend visible l'exploitation d'une injection en RCE.
- [ ] Logs des composants de la zone de confiance **et du proxy L7** → cible commune, **non inscriptible par la zone agent**. Principal artefact de détection d'exfiltration.
- [ ] Expédition distante des logs (une VM compromise ne doit pas pouvoir effacer ses traces).
- [ ] `make audit` qui **assère** l'état réel : règles d'egress, UFW, durcissement des unités, absence de credential hors zone de confiance.
- [ ] Alerting sur anomalies (nouvelle destination, upload volumineux, nouveau processus).

### Harnais

#### 🌟 Phase 8 — Installation et sécurisation du harnais

**Périmètre.** Le socle ne présuppose rien du harnais et **ne l'installe pas** : il sécurise l'environnement d'exécution autour de lui. L'installation est déléguée à un **provider interchangeable**, sur le même patron que `inference_provider` pour l'inférence.

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
| Migration complète UFW → nftables | UFW gère bien l'ingress, est déployé, et fail2ban utilise son action `ufw`. | Jamais nécessaire : les deux coexistent (Phase 1). |
| Vault / OpenBao / SPIFFE / OIDC apiserver | Se justifie quand il y a des secrets d'infrastructure à protéger. Complexité non testée = risque en soi. | Le jour où un vrai secret entre dans le périmètre. |
| Kyverno / OPA Gatekeeper côté cluster | En lecture seule, n'apporte rien. | Le jour où l'agent obtient un **verbe d'écriture** (le RBAC ne peut pas inspecter le contenu d'un manifeste : avec `create pods`, un pod `privileged` + `hostPath: /` possède le nœud). |
| Second VM pour la zone de confiance | Frontière interne faible, compensée par l'absence de secrets. | Quand un secret d'infrastructure entre dans le périmètre. |
| Outbox + broker de branches (`git am`, `format-patch`) | Surdimensionné : en GitOps, une branche est inoffensive. L'invariant est « pas de droit d'application ». La validation se fait en CI sur la PR (Phase 5). | Si le harnais doit agir **sans validation humaine** — aucun proxy ne peut distinguer une bonne proposition d'une mauvaise. |
| `kube-rbac-proxy` | Authentifie l'**appelant** avec le jeton de l'appelant → le harnais devrait *avoir* un jeton. | — |

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

# Provider d'inférence, en local
ssh {{ harness_name }}@<vm_ip> "curl -s http://127.0.0.1:11434/api/tags"

# Egress : direct doit timeouter, via le proxy doit passer (Phases 1 et 3)
ssh {{ harness_name }}@<vm_ip> "curl -m 3 -sS https://example.com"
ssh {{ harness_name }}@<vm_ip> "curl -m 5 -sS -x http://127.0.0.1:<proxy_port> https://<domaine_allowlisté>"

# Durcissement du harnais (après Phase 8)
systemd-analyze security {{ harness_name }}.service

# Broker Kubernetes (après Phase 4)
kubectl --kubeconfig=<broker_kubeconfig> auth can-i --list

# Validation du code local
tofu -chdir=iac validate && ansible-lint
```

### 📌 Point de départ recommandé

**Phase 0 faite** (les affirmations fausses sont corrigées). Prochaine étape : **Phase 1** — le seul contrôle réellement bloquant. Viennent ensuite **Phase 2** (inférence) puis **Phase 3** (proxy L7, dès qu'un déploiement a besoin d'un egress web déclaré). Les **Phases 4 et 5** ne sont à faire que si un cas d'usage le demande, et **Phase 8** une fois le harnais choisi et installable.
