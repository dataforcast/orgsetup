#!/usr/bin/env bash
# ============================================================================
# setup-all.sh — Orchestrateur : exécute toutes les étapes dans l'ordre
#
# Usage : ./setup-all.sh [--skip-cicd] [--skip-protection]
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

SKIP_CICD=false
SKIP_PROTECTION=false

for arg in "$@"; do
    case "$arg" in
        --skip-cicd)       SKIP_CICD=true ;;
        --skip-protection) SKIP_PROTECTION=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-cicd] [--skip-protection]"
            echo ""
            echo "Exécute dans l'ordre :"
            echo "  1. create-repos.sh       — Création des dépôts"
            echo "  2. setup-branches.sh     — Création des branches develop/staging"
            echo "  3. protect-repos.sh      — Protections minimales (sans required checks)"
            echo "  4. setup-cicd.sh         — Déploiement des workflows CI/CD"
            echo ""
            echo "Options :"
            echo "  --skip-cicd         Ignorer l'étape de déploiement CI/CD"
            echo "  --skip-protection   Ignorer l'étape de protection des branches"
            exit 0
            ;;
    esac
done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Setup complet — a2a-platform                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

run_step() {
    local step_num="$1"
    local step_name="$2"
    local script="$3"

    echo ""
    echo -e "${BOLD}════════ Étape ${step_num} : ${step_name} ════════${NC}"
    echo ""

    if bash "$script"; then
        echo -e "${GREEN}[OK]${NC} Étape ${step_num} terminée."
    else
        echo -e "${RED}[ÉCHEC]${NC} Étape ${step_num} a échoué."
        echo "  Corriger l'erreur puis relancer ce script."
        echo "  Les étapes déjà réussies sont idempotentes (pas de doublon)."
        exit 1
    fi
}

STEP=1

run_step $STEP "Création des dépôts" "${SCRIPT_DIR}/create-repos.sh"
((STEP++))

run_step $STEP "Création des branches" "${SCRIPT_DIR}/setup-branches.sh"
((STEP++))

if ! $SKIP_PROTECTION; then
    run_step $STEP "Protections minimales" "${SCRIPT_DIR}/protect-repos.sh"
    ((STEP++))
fi

if ! $SKIP_CICD; then
    run_step $STEP "Déploiement CI/CD" "${SCRIPT_DIR}/setup-cicd.sh"
    ((STEP++))
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Setup terminé                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Prochaines étapes :"
echo "  1. Attendre un premier run CI sur chaque dépôt"
echo "  2. Lancer ./scripts/setup-full-protection.sh"
echo "     pour ajouter les required status checks"
echo ""
