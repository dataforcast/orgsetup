#!/usr/bin/env bash
# ============================================================================
# setup-branches.sh — Crée les branches develop et staging sur chaque dépôt
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

load_token

log_step "Création des branches develop et staging sur tous les dépôts"
echo ""

TOTAL=0
SUCCESS=0
FAILED=0

for entry in "${REPO_DEFINITIONS[@]}"; do
    path="${entry%%|*}"
    repo_name="$(path_to_repo_name "$path")"
    ((TOTAL++))

    log_info "Branches pour ${BOLD}${repo_name}${NC}"

    branch_ok=true
    for branch in "${PROTECTED_BRANCHES[@]}"; do
        # Vérifier si la branche existe déjà
        existing="$(gh_api "GET" "/repos/${ORG_NAME}/${repo_name}/git/ref/heads/${branch}")"
        http_code="$(echo "$existing" | tail -n1)"

        if [[ "$http_code" == "200" ]]; then
            log_warn "  → ${branch} existe déjà sur ${repo_name}"
            continue
        fi

        if create_branch "$repo_name" "$branch" 2>/dev/null; then
            log_success "  → ${branch} créée"
        else
            log_error "  → Échec de création de ${branch}"
            branch_ok=false
        fi
        rate_limit_pause 0.5
    done

    if $branch_ok; then
        ((SUCCESS++))
    else
        ((FAILED++))
    fi
done

echo ""
log_step "Résumé"
echo "  Dépôts traités : ${TOTAL}"
echo "  Succès          : ${SUCCESS}"
echo "  Échecs          : ${FAILED}"
echo ""

if [[ $FAILED -gt 0 ]]; then
    log_warn "Certaines branches n'ont pas pu être créées."
    log_info "Vérifier que chaque dépôt a bien un commit initial sur main."
    exit 1
fi

log_success "Toutes les branches sont créées."
echo ""
log_info "Prochaine étape : exécuter ${BOLD}./scripts/protect-repos.sh${NC} pour appliquer les protections minimales."
