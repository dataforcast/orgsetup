#!/usr/bin/env bash
# ============================================================================
# diagnose.sh — Diagnostique les problèmes d'accès API GitHub
#
# Vérifie : token, scopes, permissions org, rate limit, accès repos
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

load_token

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Diagnostic GitHub API — a2a-platform              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

ISSUES=0

# ── 1. Vérification du format du token ─────────────────────────────────────
log_step "1. Format du token"

if [[ "${GITHUB_TOKEN}" == ghp_* ]]; then
    log_success "Token PAT Classic détecté (préfixe ghp_)"
elif [[ "${GITHUB_TOKEN}" == github_pat_* ]]; then
    log_warn "Token Fine-Grained détecté (préfixe github_pat_)"
    echo "  → Ce package est conçu pour un PAT Classic."
    echo "  → Un Fine-Grained token peut fonctionner mais les scopes diffèrent."
    echo "  → En cas de problème, créer un PAT Classic (voir README.md)."
elif [[ "${GITHUB_TOKEN}" == gho_* || "${GITHUB_TOKEN}" == ghu_* ]]; then
    log_error "Token OAuth/User-to-server détecté. Utiliser un PAT Classic."
    ((ISSUES++))
else
    log_warn "Préfixe de token non reconnu. Vérifier qu'il s'agit d'un PAT Classic."
fi

# ── 2. Authentification et identité ────────────────────────────────────────
log_step "2. Authentification"

response="$(gh_api "GET" "/user")"
http_code="$(echo "$response" | tail -n1)"
body="$(echo "$response" | sed '$d')"

if [[ "$http_code" == "200" ]]; then
    user_login="$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('login','?'))" 2>/dev/null)"
    log_success "Authentifié en tant que : ${BOLD}${user_login}${NC}"
    if [[ "$user_login" != "$GITHUB_USER" ]]; then
        log_warn "Attendu : ${GITHUB_USER}, obtenu : ${user_login}"
        echo "  → Le token n'appartient peut-être pas au compte dataforcast."
    fi
elif [[ "$http_code" == "401" ]]; then
    log_error "401 — Token invalide ou expiré."
    echo "  → Recréer le token sur https://github.com/settings/tokens"
    ((ISSUES++))
else
    log_error "Code HTTP inattendu : ${http_code}"
    ((ISSUES++))
fi

# ── 3. Scopes du token ─────────────────────────────────────────────────────
log_step "3. Scopes du token"

scopes_response="$(curl -s -I \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API}/user")"

scopes="$(echo "$scopes_response" | grep -i "x-oauth-scopes:" | sed 's/x-oauth-scopes: //i' | tr -d '\r')"

if [[ -z "$scopes" ]]; then
    log_warn "Aucun scope détecté dans les headers."
    echo "  → Cela peut indiquer un Fine-Grained token (pas de x-oauth-scopes)."
    echo "  → Pour un PAT Classic, les scopes attendus sont :"
    echo "      repo, admin:org, workflow, delete_repo"
else
    log_info "Scopes actuels : ${BOLD}${scopes}${NC}"
    echo ""

    REQUIRED_SCOPES=("repo" "admin:org" "workflow" "delete_repo")
    for scope in "${REQUIRED_SCOPES[@]}"; do
        if echo "$scopes" | grep -qi "$scope"; then
            log_success "  ✓ ${scope}"
        else
            log_error "  ✗ ${scope} — MANQUANT"
            ((ISSUES++))
            case "$scope" in
                repo)
                    echo "    → Nécessaire pour créer/modifier les dépôts et fichiers."
                    ;;
                admin:org)
                    echo "    → Nécessaire pour gérer l'organisation et les teams."
                    ;;
                workflow)
                    echo "    → Nécessaire pour pousser des fichiers dans .github/workflows/."
                    ;;
                delete_repo)
                    echo "    → Nécessaire uniquement pour dropall-repo.sh."
                    echo "    → Peut être omis si vous n'avez pas besoin de purger."
                    ;;
            esac
        fi
    done
fi

# ── 4. Accès à l'organisation ──────────────────────────────────────────────
log_step "4. Accès à l'organisation ${ORG_NAME}"

org_response="$(gh_api "GET" "/orgs/${ORG_NAME}")"
org_code="$(echo "$org_response" | tail -n1)"
org_body="$(echo "$org_response" | sed '$d')"

if [[ "$org_code" == "200" ]]; then
    log_success "Organisation ${ORG_NAME} accessible."

    # Vérifier le rôle de l'utilisateur
    membership="$(gh_api "GET" "/orgs/${ORG_NAME}/memberships/${GITHUB_USER:-$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('login',''))" 2>/dev/null)}")"
    mem_code="$(echo "$membership" | tail -n1)"
    mem_body="$(echo "$membership" | sed '$d')"

    if [[ "$mem_code" == "200" ]]; then
        role="$(echo "$mem_body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('role','?'))" 2>/dev/null)"
        state="$(echo "$mem_body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','?'))" 2>/dev/null)"
        log_info "  Rôle : ${BOLD}${role}${NC} (état: ${state})"
        if [[ "$role" != "admin" ]]; then
            log_warn "  → Le rôle 'admin' est recommandé pour la gestion complète."
            ((ISSUES++))
        fi
    fi
elif [[ "$org_code" == "404" ]]; then
    log_error "Organisation ${ORG_NAME} introuvable."
    echo "  → Vérifier que l'organisation existe sur https://github.com/${ORG_NAME}"
    echo "  → Créer l'organisation si nécessaire via https://github.com/organizations/plan"
    ((ISSUES++))
else
    log_error "Accès refusé à l'organisation (HTTP ${org_code})."
    ((ISSUES++))
fi

# ── 5. Rate limit ──────────────────────────────────────────────────────────
log_step "5. Rate limit"

rate="$(gh_api "GET" "/rate_limit")"
rate_code="$(echo "$rate" | tail -n1)"
rate_body="$(echo "$rate" | sed '$d')"

if [[ "$rate_code" == "200" ]]; then
    python3 -c "
import sys, json, datetime
data = json.load(sys.stdin)
core = data['resources']['core']
remaining = core['remaining']
limit = core['limit']
reset_ts = core['reset']
reset_dt = datetime.datetime.fromtimestamp(reset_ts).strftime('%H:%M:%S')
pct = (remaining / limit) * 100
status = '✓' if pct > 10 else '⚠'
print(f'  {status} {remaining}/{limit} requêtes restantes ({pct:.0f}%)')
print(f'    Reset à {reset_dt}')
if pct <= 10:
    print('  → Rate limit bas ! Attendre le reset ou réduire la fréquence.')
" <<< "$rate_body" 2>/dev/null
else
    log_warn "Impossible de lire le rate limit."
fi

# ── 6. Test de création/suppression d'un repo ─────────────────────────────
log_step "6. Test de création de dépôt (dry-run)"

TEST_REPO="_diagnostic-test-$(date +%s)"
log_info "  Création du dépôt de test : ${TEST_REPO}"

create_result="$(create_repo "$TEST_REPO" "Test diagnostic — à supprimer" "private" 2>&1)"
if echo "$create_result" | grep -q '"name"'; then
    log_success "  → Création réussie"

    # Nettoyer
    log_info "  Suppression du dépôt de test..."
    del_result="$(gh_api_call "DELETE" "/repos/${ORG_NAME}/${TEST_REPO}" "" "Suppression test" 2>&1)"
    if [[ $? -eq 0 ]]; then
        log_success "  → Suppression réussie (scope delete_repo OK)"
    else
        log_warn "  → Échec de suppression. Le scope delete_repo est peut-être manquant."
        echo "  → Supprimer manuellement : https://github.com/${ORG_NAME}/${TEST_REPO}/settings"
    fi
else
    log_error "  → Échec de création du dépôt de test"
    echo "$create_result" | head -5
    ((ISSUES++))
fi

# ── 7. Politique de l'organisation (third-party access) ───────────────────
log_step "7. Politique d'accès de l'organisation"

log_info "Vérification de la politique d'autorisation des applications..."
# Certaines orgs requièrent une approbation admin pour les PAT
# Ce n'est pas vérifiable directement par l'API, mais on peut le signaler
echo "  Si vous obtenez des erreurs 403 malgré les bons scopes :"
echo "    → L'organisation a peut-être activé 'Third-party application restrictions'"
echo "    → Aller dans https://github.com/organizations/${ORG_NAME}/settings/oauth_application_policy"
echo "    → Ou utiliser 'Personal access token' policy dans les paramètres org."
echo "    → Approuver le token si nécessaire."

# ── Résumé ─────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $ISSUES -eq 0 ]]; then
    log_success "Aucun problème détecté. L'environnement est prêt."
else
    log_error "${ISSUES} problème(s) détecté(s)."
    echo ""
    echo "  Actions recommandées :"
    echo "    1. Corriger les scopes manquants sur https://github.com/settings/tokens"
    echo "    2. Vérifier le rôle dans l'organisation"
    echo "    3. Relancer ce diagnostic après correction"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
