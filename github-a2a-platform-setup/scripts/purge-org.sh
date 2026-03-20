#!/usr/bin/env bash
# ============================================================================
# purge-org.sh — Purge complète d'une organisation GitHub
#
# Ce script supprime TOUTES les ressources d'une organisation :
#   Phase 1 : Dépôts (code, issues, PR, wikis, artefacts)
#   Phase 2 : Teams
#   Phase 3 : Webhooks de l'organisation
#   Phase 4 : Projects (classic) de l'organisation
#   Phase 5 : Packages du registre de conteneurs (GHCR)
#   Phase 6 : Suppression de l'organisation elle-même (optionnel)
#
# ⚠  IRRÉVERSIBLE — Toutes les données sont perdues définitivement.
#
# Prérequis token PAT Classic :
#   - repo, delete_repo, admin:org, write:packages, delete:packages
#   - Pour la phase 6 : l'utilisateur doit être owner de l'organisation
#
# Usage :
#   ./scripts/purge-org.sh                   Purge phases 1-5 (conserve l'org)
#   ./scripts/purge-org.sh --delete-org      Purge phases 1-6 (supprime l'org)
#   ./scripts/purge-org.sh --dry-run         Inventaire sans rien supprimer
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

load_token

# ── Options ─────────────────────────────────────────────────────────────────
DELETE_ORG=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --delete-org) DELETE_ORG=true ;;
        --dry-run)    DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [--delete-org] [--dry-run]"
            echo ""
            echo "  --dry-run       Inventaire des ressources sans suppression"
            echo "  --delete-org    Supprime aussi l'organisation elle-même (phase 6)"
            echo ""
            echo "Sans option : supprime repos, teams, webhooks, projects, packages"
            echo "              mais conserve l'organisation vide."
            exit 0
            ;;
    esac
done

# ── Fonctions utilitaires de pagination ─────────────────────────────────────
# Récupère toutes les pages d'un endpoint GET qui retourne un tableau JSON
fetch_all_pages() {
    local endpoint="$1"
    local context="${2:-Pagination}"
    local page=1
    local all_items="[]"

    while true; do
        local sep="?"
        [[ "$endpoint" == *"?"* ]] && sep="&"
        local response
        response="$(gh_api_call "GET" "${endpoint}${sep}per_page=100&page=${page}" "" "${context} p.${page}" 2>/dev/null)" || break

        local count
        count="$(echo "$response" | python3 -c "
import sys, json
items = json.load(sys.stdin)
print(len(items) if isinstance(items, list) else 0)
" 2>/dev/null)"

        if [[ "${count:-0}" -eq 0 ]]; then
            break
        fi

        all_items="$(python3 -c "
import sys, json
existing = json.loads(sys.argv[1])
new = json.load(sys.stdin)
print(json.dumps(existing + new))
" "$all_items" <<< "$response")"

        if [[ "$count" -lt 100 ]]; then
            break
        fi
        page=$((page + 1))
    done

    echo "$all_items"
}

# ── Bannière ────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if $DRY_RUN; then
echo "║       INVENTAIRE — Organisation ${ORG_NAME}               ║"
else
echo "║    ⚠  PURGE COMPLÈTE — Organisation ${ORG_NAME}  ⚠       ║"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Vérification de l'accès ─────────────────────────────────────────────────
log_step "Vérification de l'accès à l'organisation"

org_body="$(gh_api_call "GET" "/orgs/${ORG_NAME}" "" "Accès org")" || {
    log_error "Impossible d'accéder à l'organisation ${ORG_NAME}."
    echo "  Vérifier que l'organisation existe et que le token a le scope admin:org."
    exit 1
}

org_display="$(echo "$org_body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"{d.get('login','')} — {d.get('description','(pas de description)')}\")
print(f\"  Plan : {d.get('plan',{}).get('name','?')} | Repos publics : {d.get('public_repos',0)} | Repos privés : {d.get('total_private_repos',0)}\")
" 2>/dev/null)"
log_info "$org_display"
echo ""

# ── Phase d'inventaire ──────────────────────────────────────────────────────
log_step "Inventaire des ressources"

# Repos
log_info "Récupération des dépôts..."
REPOS_JSON="$(fetch_all_pages "/orgs/${ORG_NAME}/repos" "Repos")"
REPOS_COUNT="$(echo "$REPOS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)"
REPOS_NAMES="$(echo "$REPOS_JSON" | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    print(r['name'])
" 2>/dev/null)"

# Teams
log_info "Récupération des teams..."
TEAMS_JSON="$(fetch_all_pages "/orgs/${ORG_NAME}/teams" "Teams")"
TEAMS_COUNT="$(echo "$TEAMS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)"
TEAMS_DETAIL="$(echo "$TEAMS_JSON" | python3 -c "
import sys, json
for t in json.load(sys.stdin):
    print(f\"  {t['slug']} (id: {t['id']})\")
" 2>/dev/null)"

# Webhooks
log_info "Récupération des webhooks..."
HOOKS_JSON="$(fetch_all_pages "/orgs/${ORG_NAME}/hooks" "Webhooks")"
HOOKS_COUNT="$(echo "$HOOKS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)"

# Projects (classic v1)
log_info "Récupération des projects..."
PROJECTS_JSON="$(fetch_all_pages "/orgs/${ORG_NAME}/projects" "Projects")"
PROJECTS_COUNT="$(echo "$PROJECTS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)"

# Packages (GHCR container)
log_info "Récupération des packages..."
PACKAGES_JSON="$(fetch_all_pages "/orgs/${ORG_NAME}/packages?package_type=container" "Packages")"
PACKAGES_COUNT="$(echo "$PACKAGES_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)"

# ── Résumé de l'inventaire ──────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │  Ressource         │  Nombre             │"
echo "  ├─────────────────────────────────────────┤"
printf "  │  Dépôts             │  %-19s │\n" "${REPOS_COUNT:-0}"
printf "  │  Teams              │  %-19s │\n" "${TEAMS_COUNT:-0}"
printf "  │  Webhooks           │  %-19s │\n" "${HOOKS_COUNT:-0}"
printf "  │  Projects (classic) │  %-19s │\n" "${PROJECTS_COUNT:-0}"
printf "  │  Packages (GHCR)    │  %-19s │\n" "${PACKAGES_COUNT:-0}"
echo "  └─────────────────────────────────────────┘"
echo ""

if [[ "${REPOS_COUNT:-0}" -gt 0 ]]; then
    log_info "Dépôts :"
    echo "$REPOS_NAMES" | while read -r name; do
        echo "    • ${name}"
    done
    echo ""
fi

if [[ "${TEAMS_COUNT:-0}" -gt 0 ]]; then
    log_info "Teams :"
    echo "$TEAMS_DETAIL"
    echo ""
fi

# ── Mode dry-run : on s'arrête ici ──────────────────────────────────────────
if $DRY_RUN; then
    log_success "Mode dry-run : aucune ressource supprimée."
    echo ""
    log_info "Pour exécuter la purge : relancer sans --dry-run"
    if $DELETE_ORG; then
        log_warn "L'option --delete-org supprimera aussi l'organisation."
    fi
    exit 0
fi

# ── Confirmation interactive ────────────────────────────────────────────────
TOTAL_RESOURCES=$(( ${REPOS_COUNT:-0} + ${TEAMS_COUNT:-0} + ${HOOKS_COUNT:-0} + ${PROJECTS_COUNT:-0} + ${PACKAGES_COUNT:-0} ))

if [[ $TOTAL_RESOURCES -eq 0 ]] && ! $DELETE_ORG; then
    log_info "Aucune ressource à supprimer dans l'organisation."
    exit 0
fi

echo -e "${RED}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${RED}${BOLD}  ATTENTION : Cette opération est IRRÉVERSIBLE.${NC}"
echo -e "${RED}${BOLD}  ${TOTAL_RESOURCES} ressource(s) seront supprimées définitivement.${NC}"
if $DELETE_ORG; then
echo -e "${RED}${BOLD}  L'organisation ${ORG_NAME} sera elle-même supprimée.${NC}"
fi
echo -e "${RED}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo ""

# Confirmation 1 : saisir le nom de l'organisation
read -rp "Tapez le nom de l'organisation pour confirmer [${ORG_NAME}] : " confirm_org
if [[ "$confirm_org" != "${ORG_NAME}" ]]; then
    log_info "Nom incorrect. Opération annulée."
    exit 0
fi

# Confirmation 2 : saisir PURGE
echo ""
read -rp "Tapez 'PURGER' en majuscules pour confirmer la destruction : " confirm_word
if [[ "$confirm_word" != "PURGER" ]]; then
    log_info "Opération annulée."
    exit 0
fi

echo ""
log_warn "Démarrage de la purge dans 5 secondes... (Ctrl+C pour annuler)"
for i in 5 4 3 2 1; do
    printf "\r  %d..." "$i"
    sleep 1
done
printf "\r         \n"
echo ""

# ── Compteurs globaux ───────────────────────────────────────────────────────
TOTAL_DELETED=0
TOTAL_FAILED=0

report_phase() {
    local phase="$1"
    local deleted="$2"
    local failed="$3"
    echo ""
    if [[ $failed -eq 0 ]]; then
        log_success "Phase ${phase} terminée : ${deleted} supprimé(s), 0 échec."
    else
        log_warn "Phase ${phase} terminée : ${deleted} supprimé(s), ${failed} échec(s)."
    fi
    TOTAL_DELETED=$((TOTAL_DELETED + deleted))
    TOTAL_FAILED=$((TOTAL_FAILED + failed))
}

# ── Phase 1 : Suppression des dépôts ───────────────────────────────────────
log_step "Phase 1/$(( $DELETE_ORG ? 6 : 5 )) — Suppression des dépôts"

del=0; fail=0
if [[ "${REPOS_COUNT:-0}" -gt 0 ]]; then
    echo "$REPOS_NAMES" | while read -r repo; do
        [[ -z "$repo" ]] && continue
        log_info "  Suppression de ${repo}..."

        response="$(gh_api "DELETE" "/repos/${ORG_NAME}/${repo}")"
        http_code="$(echo "$response" | tail -n1)"

        case "$http_code" in
            204) log_success "    → supprimé" ;;
            403)
                log_error "    → 403 Forbidden"
                echo "      Scope delete_repo manquant ou restrictions d'accès."
                ;;
            404) log_warn "    → déjà supprimé" ;;
            *)   log_error "    → HTTP ${http_code}" ;;
        esac

        rate_limit_pause 0.5
    done
fi
# Recompter après suppression
remaining="$(fetch_all_pages "/orgs/${ORG_NAME}/repos" "Vérif repos" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)"
del=$(( ${REPOS_COUNT:-0} - ${remaining:-0} ))
fail=${remaining:-0}
report_phase "1 (Dépôts)" "$del" "$fail"

# ── Phase 2 : Suppression des teams ────────────────────────────────────────
log_step "Phase 2/$(( $DELETE_ORG ? 6 : 5 )) — Suppression des teams"

del=0; fail=0
if [[ "${TEAMS_COUNT:-0}" -gt 0 ]]; then
    echo "$TEAMS_JSON" | python3 -c "
import sys, json
for t in json.load(sys.stdin):
    print(f\"{t['slug']}\")
" 2>/dev/null | while read -r team_slug; do
        [[ -z "$team_slug" ]] && continue
        log_info "  Suppression de la team ${team_slug}..."

        response="$(gh_api "DELETE" "/orgs/${ORG_NAME}/teams/${team_slug}")"
        http_code="$(echo "$response" | tail -n1)"

        case "$http_code" in
            204) log_success "    → supprimée" ;;
            404) log_warn "    → n'existe plus" ;;
            *)   log_error "    → HTTP ${http_code}" ;;
        esac

        rate_limit_pause 0.5
    done
fi
remaining="$(fetch_all_pages "/orgs/${ORG_NAME}/teams" "Vérif teams" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)"
del=$(( ${TEAMS_COUNT:-0} - ${remaining:-0} ))
fail=${remaining:-0}
report_phase "2 (Teams)" "$del" "$fail"

# ── Phase 3 : Suppression des webhooks ─────────────────────────────────────
log_step "Phase 3/$(( $DELETE_ORG ? 6 : 5 )) — Suppression des webhooks"

del=0; fail=0
if [[ "${HOOKS_COUNT:-0}" -gt 0 ]]; then
    echo "$HOOKS_JSON" | python3 -c "
import sys, json
for h in json.load(sys.stdin):
    url = h.get('config',{}).get('url','(pas d url)')
    print(f\"{h['id']}|{url}\")
" 2>/dev/null | while IFS='|' read -r hook_id hook_url; do
        [[ -z "$hook_id" ]] && continue
        log_info "  Suppression du webhook ${hook_id} → ${hook_url}..."

        response="$(gh_api "DELETE" "/orgs/${ORG_NAME}/hooks/${hook_id}")"
        http_code="$(echo "$response" | tail -n1)"

        case "$http_code" in
            204) log_success "    → supprimé" ;;
            404) log_warn "    → n'existe plus" ;;
            *)   log_error "    → HTTP ${http_code}" ;;
        esac

        rate_limit_pause 0.5
    done
fi
remaining="$(fetch_all_pages "/orgs/${ORG_NAME}/hooks" "Vérif hooks" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)"
del=$(( ${HOOKS_COUNT:-0} - ${remaining:-0} ))
fail=${remaining:-0}
report_phase "3 (Webhooks)" "$del" "$fail"

# ── Phase 4 : Suppression des projects (classic) ──────────────────────────
log_step "Phase 4/$(( $DELETE_ORG ? 6 : 5 )) — Suppression des projects"

del=0; fail=0
if [[ "${PROJECTS_COUNT:-0}" -gt 0 ]]; then
    echo "$PROJECTS_JSON" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    print(f\"{p['id']}|{p['name']}\")
" 2>/dev/null | while IFS='|' read -r proj_id proj_name; do
        [[ -z "$proj_id" ]] && continue
        log_info "  Suppression du project '${proj_name}' (id: ${proj_id})..."

        response="$(gh_api "DELETE" "/projects/${proj_id}")"
        http_code="$(echo "$response" | tail -n1)"

        case "$http_code" in
            204) log_success "    → supprimé" ;;
            404) log_warn "    → n'existe plus" ;;
            410) log_warn "    → déjà supprimé (Gone)" ;;
            *)   log_error "    → HTTP ${http_code}" ;;
        esac

        rate_limit_pause 0.5
    done
fi
remaining="$(fetch_all_pages "/orgs/${ORG_NAME}/projects" "Vérif projects" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)"
del=$(( ${PROJECTS_COUNT:-0} - ${remaining:-0} ))
fail=${remaining:-0}
report_phase "4 (Projects)" "$del" "$fail"

# ── Phase 5 : Suppression des packages GHCR ───────────────────────────────
log_step "Phase 5/$(( $DELETE_ORG ? 6 : 5 )) — Suppression des packages (GHCR)"

del=0; fail=0
if [[ "${PACKAGES_COUNT:-0}" -gt 0 ]]; then
    echo "$PACKAGES_JSON" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    print(f\"{p['name']}|{p.get('package_type','container')}\")
" 2>/dev/null | while IFS='|' read -r pkg_name pkg_type; do
        [[ -z "$pkg_name" ]] && continue
        log_info "  Suppression du package ${pkg_name} (${pkg_type})..."

        response="$(gh_api "DELETE" "/orgs/${ORG_NAME}/packages/${pkg_type}/${pkg_name}")"
        http_code="$(echo "$response" | tail -n1)"

        case "$http_code" in
            204) log_success "    → supprimé" ;;
            404) log_warn "    → n'existe plus" ;;
            403)
                log_error "    → 403 Forbidden"
                echo "      Scopes nécessaires : write:packages + delete:packages"
                ;;
            *)   log_error "    → HTTP ${http_code}" ;;
        esac

        rate_limit_pause 0.5
    done
fi
remaining="$(fetch_all_pages "/orgs/${ORG_NAME}/packages?package_type=container" "Vérif pkgs" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)"
del=$(( ${PACKAGES_COUNT:-0} - ${remaining:-0} ))
fail=${remaining:-0}
report_phase "5 (Packages)" "$del" "$fail"

# ── Phase 6 : Suppression de l'organisation (optionnel) ───────────────────
if $DELETE_ORG; then
    log_step "Phase 6/6 — Suppression de l'organisation ${ORG_NAME}"
    echo ""
    echo -e "  ${RED}${BOLD}DERNIER AVERTISSEMENT${NC}"
    echo "  L'organisation ${ORG_NAME} et tout ce qu'elle contient"
    echo "  seront supprimés DÉFINITIVEMENT."
    echo ""
    read -rp "  Tapez 'SUPPRIMER ${ORG_NAME}' pour confirmer : " confirm_final
    if [[ "$confirm_final" != "SUPPRIMER ${ORG_NAME}" ]]; then
        log_info "Suppression de l'organisation annulée."
    else
        log_info "Suppression de l'organisation..."
        response="$(gh_api "DELETE" "/orgs/${ORG_NAME}")"
        http_code="$(echo "$response" | tail -n1)"

        case "$http_code" in
            202|204)
                log_success "Organisation ${ORG_NAME} supprimée."
                TOTAL_DELETED=$((TOTAL_DELETED + 1))
                ;;
            403)
                log_error "403 Forbidden — Seul un owner de l'organisation peut la supprimer."
                echo "  → Vérifier le rôle du compte sur https://github.com/orgs/${ORG_NAME}/people"
                TOTAL_FAILED=$((TOTAL_FAILED + 1))
                ;;
            *)
                log_error "Échec (HTTP ${http_code})"
                body="$(echo "$response" | sed '$d')"
                echo "  → $(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || echo "$body" | head -c 200)"
                TOTAL_FAILED=$((TOTAL_FAILED + 1))
                ;;
        esac
    fi
fi

# ── Résumé global ──────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [[ $TOTAL_FAILED -eq 0 ]]; then
    log_success "Purge terminée. ${TOTAL_DELETED} ressource(s) supprimée(s)."
else
    log_warn "Purge terminée avec des erreurs."
    echo "  Supprimées : ${TOTAL_DELETED}"
    echo "  Échouées   : ${TOTAL_FAILED}"
    echo ""
    log_info "Causes fréquentes d'échec :"
    echo "    • Scope delete_repo manquant       → repos non supprimés"
    echo "    • Scopes write/delete:packages      → packages non supprimés"
    echo "    • Rôle non-owner dans l'org         → org non supprimable"
    echo "    • Third-party app restrictions       → tout bloqué en 403"
    echo ""
    log_info "Lancer ${BOLD}./scripts/diagnose.sh${NC} pour un diagnostic complet."
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
