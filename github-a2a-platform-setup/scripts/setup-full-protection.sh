#!/usr/bin/env bash
# ============================================================================
# setup-full-protection.sh — Renforce les protections avec required checks
#
# À exécuter APRÈS que les pipelines CI aient tourné au moins une fois
# sur chaque dépôt. Les check contexts doivent exister dans GitHub
# pour pouvoir être référencés dans les branch protection rules.
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

load_token

# Les noms de checks CI correspondent aux job names dans les workflows
CI_CHECK_CONTEXTS=(
    "lint-and-format"
    "unit-tests"
    "security-sast"
    "docker-build"
)

log_step "Renforcement des protections avec required status checks"
echo ""
log_info "Checks requis : ${CI_CHECK_CONTEXTS[*]}"
echo ""

ALL_BRANCHES=("main" "develop" "staging")
TOTAL=0
SUCCESS=0
SKIPPED=0
FAILED=0

for entry in "${REPO_DEFINITIONS[@]}"; do
    path="${entry%%|*}"
    repo_name="$(path_to_repo_name "$path")"
    group="$(path_to_group "$path")"
    TOTAL=$((TOTAL + 1))

    # Les repos cicd-templates n'ont pas besoin de ces checks Python
    if [[ "$group" == "cicd-templates" ]]; then
        log_info "  ⊘ ${repo_name} (template, pas de checks CI Python)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    log_info "Protection renforcée de ${BOLD}${repo_name}${NC}"

    # Vérifier qu'au moins un check a déjà été exécuté
    check_runs="$(gh_api_call "GET" "/repos/${ORG_NAME}/${repo_name}/commits/main/check-runs?per_page=1" \
        "" "Vérification checks ${repo_name}" 2>/dev/null)" || true

    check_count="$(echo "$check_runs" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('total_count', 0))
except:
    print(0)
" 2>/dev/null)"

    if [[ "${check_count:-0}" -eq 0 ]]; then
        log_warn "  → Aucun check CI trouvé sur ${repo_name}. On passe."
        log_info "    Exécuter d'abord un workflow CI puis relancer ce script."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Construire le JSON des checks
    checks_json="$(printf '%s\n' "${CI_CHECK_CONTEXTS[@]}" | python3 -c "
import sys, json
contexts = [l.strip() for l in sys.stdin if l.strip()]
print(json.dumps(contexts))
")"

    repo_ok=true
    for branch in "${ALL_BRANCHES[@]}"; do
        payload=$(cat <<EOF
{
    "required_status_checks": {
        "strict": true,
        "contexts": ${checks_json}
    },
    "required_pull_request_reviews": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews": true
    },
    "enforce_admins": true,
    "restrictions": null
}
EOF
)
        if gh_api_call "PUT" "/repos/${ORG_NAME}/${repo_name}/branches/${branch}/protection" \
            "$payload" "Full protection ${branch} sur ${repo_name}" >/dev/null 2>&1; then
            log_success "  → ${branch} renforcée"
        else
            log_error "  → Échec sur ${branch}"
            repo_ok=false
        fi
        rate_limit_pause 0.5
    done

    if $repo_ok; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done

echo ""
log_step "Résumé"
echo "  Dépôts traités  : ${TOTAL}"
echo "  Renforcés        : ${SUCCESS}"
echo "  Ignorés (pas CI) : ${SKIPPED}"
echo "  Échecs           : ${FAILED}"
