---
name: github-org-setup
description: >
  Génère des scripts bash pour provisionner une organisation GitHub avec une structure
  multi-repositories pour une plateforme agentic A2A. Utiliser cette skill quand
  l'utilisateur veut créer, configurer ou gérer des dépôts GitHub pour une plateforme
  d'agents collaboratifs. Couvre : création de repos, branches protégées, workflows CI/CD
  (lint, tests, SAST, Docker build, scan, déploiement K8s), diagnostic de tokens,
  purge de repos. Se déclenche aussi pour : setup GitHub organization, provisionner
  des repos en batch, configurer des pipelines CI/CD GitHub Actions pour des agents Python,
  ou toute demande mentionnant a2a-platform, aagate, ou organisation GitHub multi-repos.
---

# GitHub Organization Setup — Plateforme Agentic A2A

Cette skill génère un package complet de scripts bash pour provisionner une organisation
GitHub destinée à une plateforme multi-agents A2A.

## Quand utiliser cette skill

- L'utilisateur demande de créer/configurer une organisation GitHub pour des agents A2A
- Setup de repos en batch dans une org GitHub
- Configuration de pipelines CI/CD GitHub Actions pour des projets Python/Docker/K8s
- Gestion de branches protégées sur de nombreux repos
- Diagnostic de problèmes de tokens GitHub API

## Architecture de la solution

GitHub Organizations n'a pas de sous-groupes hiérarchiques natifs. La hiérarchie est
simulée par :
1. **Convention de nommage à préfixes** : `groupe-sousgroupe-repo` (ex: `aagate-ComplianceAgent`)
2. **Topics GitHub** : chaque repo porte les topics de ses groupes parents + `a2a-platform`

## Structure du livrable

Le package `github-a2a-platform-setup.tar.gz` contient :

```
github-a2a-platform-setup/
├── setup-all.sh                  # Orchestrateur principal
├── README.md                     # Documentation complète
├── scripts/
│   ├── common.sh                 # Fonctions partagées (API, logging, définitions repos)
│   ├── create-repos.sh           # Création de tous les repos
│   ├── setup-branches.sh         # Branches develop + staging
│   ├── protect-repos.sh          # Protections minimales (sans required checks)
│   ├── setup-full-protection.sh  # Protections renforcées (après 1er run CI)
│   ├── setup-cicd.sh             # Déploiement des workflows CI/CD
│   ├── diagnose.sh               # Diagnostic token/permissions/rate-limit
│   └── dropall-repo.sh           # Purge complète (irréversible)
└── templates/workflows/
    ├── ci-python.yml             # Pipeline CI : lint → tests → SAST → Docker build
    └── cd-deploy.yml             # Pipeline CD : scan → push GHCR → deploy K8s
```

## Principes de conception des scripts

1. **Factorisation** : toute logique partagée est dans `common.sh` (appels API, gestion
   d'erreurs HTTP, création de repos/branches, protections). Zéro duplication.

2. **Idempotence** : les scripts détectent les ressources existantes et les sautent
   sans erreur. On peut relancer à tout moment.

3. **Gestion d'erreurs explicite** : chaque code HTTP (401, 403, 404, 422) produit un
   message contextualisé avec l'action corrective à entreprendre.

4. **Rate limiting** : pauses intégrées entre les appels API pour éviter les limites
   secondaires de GitHub.

5. **Protections progressives** : les branch protections sont appliquées en deux temps
   car un check ne peut être requis que s'il a déjà existé dans le repo.

## Personnalisation

Pour adapter à un autre projet, modifier dans `scripts/common.sh` :
- `ORG_NAME` : nom de l'organisation GitHub
- `GITHUB_USER` : compte administrateur
- `REPO_DEFINITIONS` : tableau des repos avec chemin hiérarchique et description
- `PROTECTED_BRANCHES` : branches à protéger

Les templates CI/CD dans `templates/workflows/` peuvent être adaptés selon la stack
(remplacer Ruff par Black, ajouter des étapes SonarQube, etc.).

## Référence : Token PAT Classic

Scopes requis : `repo`, `admin:org`, `workflow`, `delete_repo` (optionnel).
Voir le README.md du package pour les instructions détaillées de création.

## Référence : Pipelines CI/CD

### CI (ci-python.yml)
Lint (Ruff/Mypy) → Tests (Pytest) → Sécurité (Bandit + pip-audit + Gitleaks) → Build Docker

### CD (cd-deploy.yml)
Scan Trivy → Push GHCR → Deploy K8s (develop→dev, staging→staging, main→production)

Déclenché uniquement sur les branches `develop`, `staging`, `main`.
