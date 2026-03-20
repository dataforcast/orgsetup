#!/usr/bin/env bash
# ============================================================================
# setup-cicd.sh — Déploie les workflows CI/CD dans chaque dépôt
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$(cd "${SCRIPT_DIR}/../templates/workflows" && pwd)"
source "${SCRIPT_DIR}/common.sh"

load_token

log_step "Déploiement des workflows CI/CD dans les dépôts"
echo ""

# Groupes qui contiennent des agents Python (reçoivent les workflows CI/CD)
AGENT_GROUPS=("easytalk" "universes" "aagate" "nlp")

# Groupes d'infrastructure (pas de workflow Python)
INFRA_GROUPS=("cloud-infra" "cicd-templates")

is_agent_repo() {
    local group="$1"
    for ag in "${AGENT_GROUPS[@]}"; do
        # Le groupe "universes" couvre universes/telco, universes/money, etc.
        if [[ "$group" == "$ag" ]]; then
            return 0
        fi
    done
    return 1
}

TOTAL=0
DEPLOYED=0
SKIPPED=0
FAILED=0

for entry in "${REPO_DEFINITIONS[@]}"; do
    path="${entry%%|*}"
    repo_name="$(path_to_repo_name "$path")"
    group="$(path_to_group "$path")"
    ((TOTAL++))

    if ! is_agent_repo "$group"; then
        log_info "  ⊘ ${repo_name} (infra/template, pas de workflow Python)"
        ((SKIPPED++))
        continue
    fi

    log_info "Workflows pour ${BOLD}${repo_name}${NC}"

    repo_ok=true
    for workflow_file in "${TEMPLATES_DIR}"/*.yml; do
        filename="$(basename "$workflow_file")"
        content_b64="$(base64 -w0 < "$workflow_file")"
        target_path=".github/workflows/${filename}"

        # Vérifier si le fichier existe déjà
        existing="$(gh_api "GET" "/repos/${ORG_NAME}/${repo_name}/contents/${target_path}")"
        http_code="$(echo "$existing" | tail -n1)"

        if [[ "$http_code" == "200" ]]; then
            # Le fichier existe : récupérer son SHA pour le mettre à jour
            file_sha="$(echo "$existing" | sed '$d' | python3 -c "
import sys, json
print(json.load(sys.stdin).get('sha', ''))
" 2>/dev/null)"
            payload=$(cat <<EOF
{
    "message": "chore: update ${filename} workflow",
    "content": "${content_b64}",
    "sha": "${file_sha}",
    "branch": "main"
}
EOF
)
            if gh_api_call "PUT" "/repos/${ORG_NAME}/${repo_name}/contents/${target_path}" \
                "$payload" "Mise à jour ${filename}" >/dev/null 2>&1; then
                log_success "  → ${filename} mis à jour"
            else
                log_error "  → Échec mise à jour ${filename}"
                repo_ok=false
            fi
        else
            # Le fichier n'existe pas : le créer
            if add_file_to_repo "$repo_name" "$target_path" "$content_b64" \
                "ci: add ${filename} workflow" "main" 2>/dev/null; then
                log_success "  → ${filename} ajouté"
            else
                log_error "  → Échec ajout ${filename}"
                repo_ok=false
            fi
        fi

        rate_limit_pause 1
    done

    if $repo_ok; then
        ((DEPLOYED++))
    else
        ((FAILED++))
    fi
done

echo ""
log_step "Résumé"
echo "  Total traité    : ${TOTAL}"
echo "  Workflows posés : ${DEPLOYED}"
echo "  Ignorés (infra) : ${SKIPPED}"
echo "  Échecs          : ${FAILED}"
echo ""

if [[ $FAILED -gt 0 ]]; then
    log_warn "Certains workflows n'ont pas pu être déployés."
    exit 1
fi

log_success "Workflows CI/CD déployés."
echo ""
log_info "Les pipelines se déclencheront au prochain push sur develop, staging ou main."
log_info "Après un premier run CI réussi, lancer ${BOLD}./scripts/setup-full-protection.sh${NC}"
