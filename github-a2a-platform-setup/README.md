# github-a2a-platform-setup

Scripts de provisioning pour l'organisation GitHub **a2a-platform** — une plateforme agentic multi-repositories basée sur le protocole A2A.

## Prérequis

- **OS** : Linux/Ubuntu (ou WSL)
- **curl** : pour les appels API GitHub
- **python3** : pour le parsing JSON des réponses API
- **base64** : pour l'encodage des fichiers poussés dans les repos
- **bash** : version 4+ (tableaux associatifs)

## 1. Création du token GitHub (PAT Classic)

Les scripts utilisent l'API REST GitHub authentifiée par un **Personal Access Token (PAT) Classic**.

### Étapes de création

1. Se connecter au compte **dataforcast** sur [github.com](https://github.com)
2. Aller dans **Settings → Developer settings → Personal access tokens → Tokens (classic)**
   - URL directe : <https://github.com/settings/tokens>
3. Cliquer sur **"Generate new token" → "Generate new token (classic)"**
4. Renseigner :
   - **Note** : `a2a-platform-setup`
   - **Expiration** : 90 jours (ou "No expiration" pour le provisioning initial)
5. Cocher les **scopes** suivants :

### Scopes requis

| Scope | Raison |
|---|---|
| **`repo`** | Accès complet aux dépôts privés : création, modification de contenu, gestion des branches et protections |
| **`admin:org`** | Gestion de l'organisation : lecture de la configuration, gestion des teams et des memberships |
| **`workflow`** | Permet de pousser des fichiers dans `.github/workflows/` (les commits modifiant des workflows GitHub Actions requièrent ce scope) |
| **`delete_repo`** | Nécessaire pour `dropall-repo.sh` et `purge-org.sh` (purge des dépôts). Peut être omis si la purge n'est pas envisagée |
| **`write:packages`** | Nécessaire pour `purge-org.sh` phase 5 (suppression des packages GHCR). Optionnel |
| **`delete:packages`** | Nécessaire pour `purge-org.sh` phase 5 (suppression des packages GHCR). Optionnel |

6. Cliquer sur **"Generate token"**
7. **Copier immédiatement le token** (il ne sera plus visible après).

### Configuration du token

Deux options :

```bash
# Option A : variable d'environnement (session courante)
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# Option B : fichier persistant
echo "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" > ~/.github-a2a-token
chmod 600 ~/.github-a2a-token
```

### Vérification

```bash
./scripts/diagnose.sh
```

Ce script vérifie le format du token, les scopes, l'accès à l'organisation, le rate limit et la capacité de création/suppression de dépôts.

## 2. Structure de l'organisation

GitHub Organizations n'a pas de sous-groupes hiérarchiques natifs (contrairement à GitLab). La hiérarchie est simulée par une **convention de nommage à préfixes** et des **topics** GitHub :

```
a2a-platform (organisation)
│
├── easytalk-SupervisorAgent          # topic: easytalk
├── easytalk-SearchAgent
├── easytalk-IntentAgent
├── easytalk-DataModel
│
├── universes-telco-PassAgent         # topics: universes, telco
├── universes-telco-SubscriptionAgent
├── universes-money-TransferAgent     # topics: universes, money
├── universes-money-PaymentAgent
├── universes-money-WalletAgent
├── universes-tv-ProgramAgent         # topics: universes, tv
│
├── aagate-ComplianceAgent            # topic: aagate
├── aagate-GoverningOrchestratorAgent
├── aagate-ShadowMonitorAgent
├── aagate-OpenPolicyAgent
│
├── a2a-RegistryAgent            # topic: a2a
├── a2a-NamingSpaceAgent   # topic: a2a
│
├── cloudinfra-istio-config          # topic: cloudinfra
├── cloudinfra-s3
├── cloudinfra-kafka
├── cloudinfra-reddisStream
├── cloudinfra-reddis
│
├── cicdtemplates-ci-templates       # topic: cicdtemplates
├── cicdtemplates-security-pipelines
├── cicdtemplates-helm-charts
├── cicdtemplates-qa-templates
│
└── nlp-WolofEnabler                  # topic: nlp
```

Tous les dépôts portent le topic `a2a-platform` en complément. On peut filtrer par groupe via la recherche GitHub : `topic:aagate` ou `topic:universes`.

## 3. Exécution des scripts

### Installation

```bash
tar xzf github-a2a-platform-setup.tar.gz
cd github-a2a-platform-setup
chmod +x setup-all.sh scripts/*.sh
```

### Setup complet (recommandé)

```bash
export GITHUB_TOKEN="ghp_..."
./setup-all.sh
```

Ce script orchestre les étapes dans l'ordre :

1. **Création des dépôts** (`create-repos.sh`)
2. **Création des branches** develop et staging (`setup-branches.sh`)
3. **Protections minimales** sans required checks (`protect-repos.sh`)
4. **Déploiement des workflows CI/CD** (`setup-cicd.sh`)

Options :
- `--skip-cicd` : ne pas déployer les workflows CI/CD
- `--skip-protection` : ne pas appliquer les protections de branches

### Exécution étape par étape

```bash
# 1. Diagnostic préalable
./scripts/diagnose.sh

# 2. Créer les dépôts
./scripts/create-repos.sh

# 3. Créer les branches develop et staging
./scripts/setup-branches.sh

# 4. Protections minimales (PR review obligatoire, pas de required checks)
./scripts/protect-repos.sh

# 5. Déployer les workflows CI/CD
./scripts/setup-cicd.sh

# 6. APRÈS un premier run CI réussi : renforcer les protections
./scripts/setup-full-protection.sh
```

## 4. Pipelines CI/CD

### Pipeline CI (`ci-python.yml`)

Déclenché sur push et pull request vers `develop`, `staging`, `main` :

| Étape | Outil | Détails |
|---|---|---|
| Lint & Format | Ruff, Mypy | Vérification du style et du typage |
| Tests unitaires | Pytest | Couverture de code en sortie |
| Sécurité SAST | Bandit | Analyse statique du code Python |
| Dépendances | pip-audit | Détection de vulnérabilités connues |
| Détection de secrets | Gitleaks | Empêche les commits avec des secrets |
| Build Docker | Buildx | Construction de l'image (sans push) |

### Pipeline CD (`cd-deploy.yml`)

Déclenché après un CI réussi sur `develop`, `staging`, `main` :

| Étape | Outil | Détails |
|---|---|---|
| Scan de l'image | Trivy | Détection de vulnérabilités CRITICAL/HIGH |
| Push registry | GHCR | Push vers GitHub Container Registry |
| Déploiement K8s | kubectl | Mise à jour du déploiement sur le cluster |

Mapping des branches vers les environnements :
- `develop` → environnement **dev**
- `staging` → environnement **staging**
- `main` → environnement **production**

## 5. Branches protégées

Trois branches protégées : `main`, `develop`, `staging`.

**Protections minimales** (appliquées immédiatement par `protect-repos.sh`) :
- Pull request obligatoire avec 1 approbation
- Dismiss des reviews obsolètes lors de nouveaux commits
- Pas de force-push

**Protections renforcées** (après un premier run CI, via `setup-full-protection.sh`) :
- Toutes les protections minimales
- Required status checks : `lint-and-format`, `unit-tests`, `security-sast`, `docker-build`
- Branche à jour obligatoire avant merge (`strict: true`)
- Enforce admins

## 6. Scripts utilitaires

### `diagnose.sh` — Diagnostic complet

Vérifie en 7 étapes : format du token, authentification, scopes, accès org, rôle utilisateur, rate limit, et test de création/suppression.

```bash
./scripts/diagnose.sh
```

### `dropall-repo.sh` — Purge des dépôts

Supprime tous les dépôts pour repartir de zéro. Double confirmation requise.

```bash
# Supprimer uniquement les dépôts définis dans le projet
./scripts/dropall-repo.sh --only-defined

# Supprimer TOUS les dépôts de l'organisation
./scripts/dropall-repo.sh
```

### `purge-org.sh` — Purge complète de l'organisation

Supprime **toutes les ressources** d'une organisation GitHub en 6 phases séquentielles. Chaque phase vérifie le résultat avant de passer à la suivante.

| Phase | Ressources supprimées |
|---|---|
| 1 | Tous les dépôts (code, issues, PR, wikis, artefacts CI) |
| 2 | Toutes les teams |
| 3 | Tous les webhooks de l'organisation |
| 4 | Tous les projects (classic) |
| 5 | Tous les packages du registre GHCR |
| 6 | L'organisation elle-même *(optionnel, `--delete-org`)* |

**Sécurité** : le script demande 3 confirmations avant de commencer la purge, puis laisse un délai de 5 secondes (annulable par Ctrl+C) avant l'exécution.

```bash
# Inventaire sans rien supprimer (dry-run)
./scripts/purge-org.sh --dry-run

# Purge phases 1-5 : supprime tout, conserve l'org vide
./scripts/purge-org.sh

# Purge phases 1-6 : supprime tout ET l'organisation
./scripts/purge-org.sh --delete-org
```

**Scopes supplémentaires requis** : `delete_repo`, `write:packages`, `delete:packages`. Pour la phase 6, le compte doit être **owner** de l'organisation.

## 7. Dépannage

### Erreurs 401 — Unauthorized
- Token expiré ou invalide → régénérer sur <https://github.com/settings/tokens>
- Vérifier avec `./scripts/diagnose.sh`

### Erreurs 403 — Forbidden
- Scopes manquants (vérifier `repo`, `admin:org`, `workflow`)
- L'organisation a activé les restrictions d'accès tiers :
  → <https://github.com/organizations/a2a-platform/settings/oauth_application_policy>
- Rate limit atteint → attendre le reset (~1h)

### Erreurs 404 — Not Found
- L'organisation `a2a-platform` n'existe pas encore → la créer
- Le dépôt référencé n'a pas été créé → lancer `create-repos.sh`

### Erreurs 422 — Unprocessable Entity
- Nom de dépôt déjà pris → le script gère ce cas (skip)
- Branche de protection inexistante → lancer `setup-branches.sh` d'abord

### Les required status checks échouent
- Les checks CI n'ont jamais tourné sur le dépôt
- Lancer un premier push pour déclencher le CI, puis `setup-full-protection.sh`

## 8. Ajouter un nouveau dépôt

L'ajout d'un dépôt au projet se fait en 3 étapes : déclarer, provisionner, vérifier.

### Étape 1 — Déclarer le dépôt dans `common.sh`

Ouvrir `scripts/common.sh` et ajouter une entrée dans le tableau `REPO_DEFINITIONS`. Le format est :

```
"chemin/hiérarchique/NomRepo|Description du dépôt"
```

Le chemin hiérarchique définit le groupe (et sous-groupe éventuel) auquel appartient le dépôt. Le nom du repo GitHub créé sera la concaténation des segments séparés par des tirets.

**Exemples selon les cas d'usage :**

```bash
declare -a REPO_DEFINITIONS=(
    # ... dépôts existants ...

    # Cas 1 — Nouvel agent dans un groupe existant (easytalk)
    "easytalk/SummaryAgent|Agent de résumé conversationnel EasyTalk"
    #  → Repo GitHub : easytalk-SummaryAgent
    #  → Topics : a2a-platform, easytalk

    # Cas 2 — Nouvel agent dans un sous-groupe existant (universes/telco)
    "universes/telco/RoamingAgent|Agent de gestion du roaming télécom"
    #  → Repo GitHub : universes-telco-RoamingAgent
    #  → Topics : a2a-platform, universes, telco

    # Cas 3 — Nouveau sous-groupe dans un groupe existant
    "universes/insurance/ClaimAgent|Agent de gestion des sinistres assurance"
    "universes/insurance/PolicyAgent|Agent de gestion des polices assurance"
    #  → Repos : universes-insurance-ClaimAgent, universes-insurance-PolicyAgent
    #  → Topics : a2a-platform, universes, insurance

    # Cas 4 — Nouveau groupe à la racine
    "analytics/DashboardAgent|Agent tableau de bord analytique"
    "analytics/MetricsCollector|Collecteur de métriques OpenTelemetry"
    #  → Repos : analytics-DashboardAgent, analytics-MetricsCollector
    #  → Topics : a2a-platform, analytics

    # Cas 5 — Nouveau composant d'infrastructure
    "cloud-infra/PostgreSQL|Configuration PostgreSQL"
    #  → Repo : cloud-infra-PostgreSQL
    #  → Topics : a2a-platform, cloud-infra
)
```

**Si le nouveau dépôt est un agent Python** (et non de l'infra ou des templates), vérifier que son groupe racine est listé dans `AGENT_GROUPS` du script `setup-cicd.sh`, sinon les workflows CI/CD ne seront pas déployés dessus :

```bash
# Dans scripts/setup-cicd.sh — ajouter le nouveau groupe si nécessaire
AGENT_GROUPS=("easytalk" "universes" "aagate" "nlp" "analytics")
#                                                      ^^^^^^^^ ajouté
```

### Étape 2 — Provisionner le dépôt

Relancer `setup-all.sh`. Les scripts sont **idempotents** : les dépôts existants sont ignorés, seuls les nouveaux sont créés.

```bash
export GITHUB_TOKEN="ghp_..."
./setup-all.sh
```

Pour provisionner uniquement le nouveau dépôt sans tout relancer, exécuter les scripts individuellement — ils itèrent sur la liste complète mais sautent les repos déjà existants :

```bash
./scripts/create-repos.sh          # Crée le repo
./scripts/setup-branches.sh        # Crée develop + staging
./scripts/protect-repos.sh         # Applique les protections minimales
./scripts/setup-cicd.sh            # Déploie les workflows CI/CD (si agent)
```

### Étape 3 — Vérifier

```bash
# Vérifier que le repo existe et a les bonnes branches
curl -s -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/repos/a2a-platform/easytalk-SummaryAgent/branches \
  | python3 -c "import sys,json; [print(b['name']) for b in json.load(sys.stdin)]"
# Attendu : main, develop, staging

# Vérifier les topics
curl -s -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/repos/a2a-platform/easytalk-SummaryAgent/topics \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('names',[]))"
# Attendu : ['a2a-platform', 'easytalk']
```

Après le premier push et un run CI réussi, renforcer les protections :

```bash
./scripts/setup-full-protection.sh
```
