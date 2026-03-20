#!/usr/bin/env bash
# ============================================================================
# dropall-repo.sh — Supprime TOUS les dépôts créés dans l'organisation
#
# ⚠ ATTENTION : Cette opération est IRRÉVERSIBLE.
# Elle supprime définitivement les dépôts, l'historique Git, les issues,
# les workflows et tous les artefacts associés.
#
# Prérequis : le token doit avoir le scope delete_repo.
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

load_token

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     ⚠  SUPPRESSION DE TOUS LES DÉPÔTS a2a-platform  ⚠     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

MODE="${1:-}"

if [[ "$MODE" == "--only-defined" ]]; then
    log_info "Mode : suppression des dépôts définis dans common.sh uniquement."
    echo ""
else
    log_info "Mode : suppression de TOUS les dépôts de l'organisation."
    log_info "  Pour ne supprimer que les dépôts du projet, ajouter --only-defined"
    echo ""
fi

# Demander une confirmation explicite
echo -e "${RED}${BOLD}Cette opération est IRRÉVERSIBLE.${NC}"
echo ""
read -rp "Tapez 'SUPPRIMER' en majuscules pour confirmer : " confirm

if [[ "$confirm" != "SUPPRIMER" ]]; then
    log_info "Opération annulée."
    exit 0
fi

echo ""

# Construire la liste des dépôts à supprimer
REPOS_TO_DELETE=()

if [[ "$MODE" == "--only-defined" ]]; then
    for entry in "${REPO_DEFINITIONS[@]}"; do
        path="${entry%%|*}"
        REPOS_TO_DELETE+=("$(path_to_repo_name "$path")")
    done
else
    log_info "Récupération de la liste complète des dépôts..."
    while IFS= read -r repo; do
        [[ -n "$repo" ]] && REPOS_TO_DELETE+=("$repo")
    done < <(list_org_repos)
fi

TOTAL="${#REPOS_TO_DELETE[@]}"

if [[ $TOTAL -eq 0 ]]; then
    log_info "Aucun dépôt à supprimer."
    exit 0
fi

log_warn "${TOTAL} dépôt(s) à supprimer :"
for repo in "${REPOS_TO_DELETE[@]}"; do
    echo "    - ${repo}"
done
echo ""

read -rp "Confirmer la suppression de ${TOTAL} dépôt(s) ? [y/N] " final_confirm
if [[ "${final_confirm,,}" != "y" ]]; then
    log_info "Opération annulée."
    exit 0
fi

echo ""
DELETED=0
FAILED=0

for repo in "${REPOS_TO_DELETE[@]}"; do
    log_info "Suppression de ${BOLD}${repo}${NC}..."

    response="$(gh_api "DELETE" "/repos/${ORG_NAME}/${repo}")"
    http_code="$(echo "$response" | tail -n1)"

    case "$http_code" in
        204)
            log_success "  → ${repo} supprimé"
            ((DELETED++))
            ;;
        403)
            log_error "  → 403 Forbidden : scope delete_repo manquant ou restrictions org."
            echo "    → Ajouter le scope delete_repo au token PAT."
            ((FAILED++))
            ;;
        404)
            log_warn "  → ${repo} n'existe pas (déjà supprimé ?)"
            ((DELETED++))
            ;;
        *)
            log_error "  → Échec (HTTP ${http_code})"
            ((FAILED++))
            ;;
    esac

    rate_limit_pause 0.5
done

echo ""
log_step "Résumé"
echo "  Supprimés : ${DELETED}"
echo "  Échecs    : ${FAILED}"
echo ""

if [[ $FAILED -gt 0 ]]; then
    log_warn "Certains dépôts n'ont pas pu être supprimés."
    log_info "Lancer ${BOLD}./scripts/diagnose.sh${NC} pour vérifier les permissions."
else
    log_success "Tous les dépôts ont été supprimés."
    echo ""
    log_info "Vous pouvez relancer la création avec ${BOLD}./scripts/create-repos.sh${NC}"
fi
