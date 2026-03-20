#!/usr/bin/env bash
# ============================================================================
# create-repos.sh — Crée tous les dépôts de l'organisation a2a-platform
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

load_token

log_step "Création des dépôts dans l'organisation ${ORG_NAME}"
echo ""

# Vérifier que l'organisation est accessible
log_info "Vérification de l'accès à l'organisation ${ORG_NAME}..."
org_check="$(gh_api_call "GET" "/orgs/${ORG_NAME}" "" "Accès organisation")" || exit 1
log_success "Organisation ${ORG_NAME} accessible."

# Collecter les groupes uniques pour créer des teams GitHub
declare -A GROUPS_SEEN
TOTAL=0
CREATED=0
SKIPPED=0
FAILED=0

for entry in "${REPO_DEFINITIONS[@]}"; do
    path="${entry%%|*}"
    description="${entry##*|}"
    repo_name="$(path_to_repo_name "$path")"
    group="$(path_to_group "$path")"
    GROUPS_SEEN["$group"]=1

    log_info "Création du dépôt : ${BOLD}${repo_name}${NC}"
    TOTAL=$((TOTAL + 1))

    result="$(create_repo "$repo_name" "$description" "private" 2>&1)" && {
        if echo "$result" | grep -q '"name"'; then
            log_success "  → ${repo_name} créé."
            CREATED=$((CREATED + 1))
        else
            log_warn "  → ${repo_name} existait déjà."
            SKIPPED=$((SKIPPED + 1))
        fi
    } || {
        echo "$result"
        FAILED=$((FAILED + 1))
    }

    rate_limit_pause 1
done

# Ajouter des topics GitHub pour simuler la hiérarchie de groupes
log_step "Application des topics (groupes) sur les dépôts"
for entry in "${REPO_DEFINITIONS[@]}"; do
    path="${entry%%|*}"
    repo_name="$(path_to_repo_name "$path")"

    # Construire la liste de topics à partir du chemin hiérarchique
    IFS='/' read -ra parts <<< "$path"
    topics=()
    topics+=("a2a-platform")
    cumulative=""
    for part in "${parts[@]}"; do
        if [[ -z "$cumulative" ]]; then
            cumulative="$part"
        else
            cumulative="${cumulative}-${part}"
        fi
        # Le dernier segment est le repo lui-même, pas un topic de groupe
    done
    # Tous les segments sauf le dernier sont des topics de groupe
    group_topics=()
    group_topics+=("a2a-platform")
    for (( i=0; i<${#parts[@]}-1; i++ )); do
        group_topics+=("${parts[$i]}")
    done

    topics_json="$(printf '%s\n' "${group_topics[@]}" | python3 -c "
import sys, json
names = [line.strip().lower() for line in sys.stdin if line.strip()]
print(json.dumps({'names': names}))
")"

    gh_api_call "PUT" "/repos/${ORG_NAME}/${repo_name}/topics" \
        "$topics_json" "Topics sur ${repo_name}" >/dev/null 2>&1 || true

    rate_limit_pause 0.5
done

# Résumé
echo ""
log_step "Résumé de la création des dépôts"
echo "  Total traité : ${TOTAL}"
echo "  Créés         : ${CREATED}"
echo "  Déjà existants: ${SKIPPED}"
echo "  Échecs        : ${FAILED}"
echo ""

if [[ $FAILED -gt 0 ]]; then
    log_warn "Certains dépôts n'ont pas pu être créés. Lancer diagnose.sh pour identifier les causes."
    exit 1
fi

log_success "Tous les dépôts sont prêts."
echo ""
log_info "Prochaine étape : exécuter ${BOLD}./scripts/setup-branches.sh${NC} pour créer les branches develop et staging."
