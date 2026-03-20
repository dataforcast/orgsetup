#!/usr/bin/env bash
# ============================================================================
# protect-repos.sh — Applique des protections minimales sur les branches
#
# Pourquoi ce script est séparé :
#   Les required status checks ne peuvent référencer que des contextes
#   (noms de checks CI) qui ont déjà été exécutés récemment sur le dépôt.
#   Sur un dépôt fraîchement créé, aucun check n'existe encore.
#
#   Ce script applique donc des protections SANS required_status_checks :
#     - Pull request obligatoire avec 1 approbation
#     - Dismiss des reviews obsolètes
#     - Pas de force-push
#
#   Une fois que les pipelines CI auront tourné au moins une fois,
#   on pourra renforcer les protections avec setup-full-protection.sh.
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

load_token

log_step "Application des protections minimales sur les branches"
echo ""
log_info "Les required_status_checks seront ajoutés plus tard"
log_info "une fois que les pipelines CI auront produit au moins un run."
echo ""

ALL_BRANCHES=("main" "develop" "staging")
TOTAL=0
SUCCESS=0
FAILED=0

for entry in "${REPO_DEFINITIONS[@]}"; do
    path="${entry%%|*}"
    repo_name="$(path_to_repo_name "$path")"
    ((TOTAL++))

    log_info "Protection de ${BOLD}${repo_name}${NC}"

    repo_ok=true
    for branch in "${ALL_BRANCHES[@]}"; do
        if protect_branch_minimal "$repo_name" "$branch" 2>/dev/null; then
            log_success "  → ${branch} protégée"
        else
            log_error "  → Échec de protection de ${branch} sur ${repo_name}"
            repo_ok=false
        fi
        rate_limit_pause 0.5
    done

    if $repo_ok; then
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
    log_warn "Certaines protections n'ont pas pu être appliquées."
    log_info "Causes possibles :"
    echo "    - La branche n'existe pas encore → lancer setup-branches.sh d'abord"
    echo "    - Le plan GitHub ne supporte pas les branch protections"
    echo "      (nécessite GitHub Team ou Enterprise pour les repos privés)"
    exit 1
fi

log_success "Protections minimales appliquées sur tous les dépôts."
echo ""
log_info "Prochaine étape : exécuter ${BOLD}./scripts/setup-cicd.sh${NC} pour déployer les workflows CI/CD."
log_info "Puis, après un premier run CI réussi, lancer ${BOLD}./scripts/setup-full-protection.sh${NC}"
