#!/usr/bin/env bash
# ============================================================================
# common.sh — Fonctions partagées par tous les scripts du package
# ============================================================================
set -euo pipefail

# ── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Variables globales ──────────────────────────────────────────────────────
GITHUB_API="https://api.github.com"
ORG_NAME="a2a-platform"
GITHUB_USER="dataforcast"

# ── Logging ─────────────────────────────────────────────────────────────────
log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}▸ $*${NC}"; }

# ── Validation du token ────────────────────────────────────────────────────
load_token() {
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        if [[ -f "$HOME/.github-a2a-token" ]]; then
            GITHUB_TOKEN="$(cat "$HOME/.github-a2a-token" | tr -d '[:space:]')"
            export GITHUB_TOKEN
        else
            log_error "Variable GITHUB_TOKEN non définie."
            echo ""
            echo "  Deux options :"
            echo "    1. export GITHUB_TOKEN='ghp_xxxxxxxxxxxx'"
            echo "    2. Écrire le token dans ~/.github-a2a-token"
            echo ""
            echo "  Voir README.md pour la création du token PAT Classic."
            exit 1
        fi
    fi
}

# ── Appels API GitHub ───────────────────────────────────────────────────────
gh_api() {
    # Usage: gh_api METHOD ENDPOINT [DATA]
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local url="${GITHUB_API}${endpoint}"

    local curl_args=(
        -s -w "\n%{http_code}"
        -X "$method"
        -H "Authorization: token ${GITHUB_TOKEN}"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )
    if [[ -n "$data" ]]; then
        curl_args+=(-H "Content-Type: application/json" -d "$data")
    fi

    curl "${curl_args[@]}" "$url"
}

# Exécute un appel API et gère les erreurs courantes.
# Retourne le body JSON sur stdout ; code retour 0 = succès.
gh_api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local context="${4:-Appel API}"

    local response
    response="$(gh_api "$method" "$endpoint" "$data")"

    local http_code
    http_code="$(echo "$response" | tail -n1)"
    local body
    body="$(echo "$response" | sed '$d')"

    case "$http_code" in
        2[0-9][0-9])
            echo "$body"
            return 0
            ;;
        401)
            log_error "$context — 401 Unauthorized"
            echo "  → Le token est invalide ou expiré."
            echo "  → Recréer un PAT Classic avec les bons scopes (voir README.md)."
            return 1
            ;;
        403)
            log_error "$context — 403 Forbidden"
            local msg
            msg="$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || echo "")"
            if [[ "$msg" == *"rate limit"* ]]; then
                echo "  → Rate limit atteint. Attendre quelques minutes."
            elif [[ "$msg" == *"secondary rate limit"* ]]; then
                echo "  → Rate limit secondaire. Réduire la fréquence des appels."
            else
                echo "  → Permissions insuffisantes. Vérifier les scopes du token."
                echo "  → Message : $msg"
            fi
            return 1
            ;;
        404)
            log_error "$context — 404 Not Found"
            echo "  → Ressource introuvable. Vérifier le nom de l'organisation et les droits."
            return 1
            ;;
        422)
            local msg
            msg="$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); errs=d.get('errors',[]); print('; '.join(e.get('message','') for e in errs) if errs else d.get('message','Validation error'))" 2>/dev/null || echo "Erreur de validation")"
            # Si le repo existe déjà, ce n'est pas bloquant
            if [[ "$msg" == *"already exists"* || "$msg" == *"name already exists"* ]]; then
                log_warn "$context — Le dépôt existe déjà, on continue."
                echo "$body"
                return 0
            fi
            log_error "$context — 422 Unprocessable Entity"
            echo "  → $msg"
            return 1
            ;;
        *)
            log_error "$context — HTTP $http_code"
            echo "  → Réponse inattendue. Body : $(echo "$body" | head -c 300)"
            return 1
            ;;
    esac
}

# ── Création d'un dépôt ────────────────────────────────────────────────────
create_repo() {
    local repo_name="$1"
    local description="${2:-}"
    local visibility="${3:-private}"

    local payload
    payload=$(cat <<EOF
{
    "name": "${repo_name}",
    "description": "${description}",
    "private": $([ "$visibility" = "private" ] && echo "true" || echo "false"),
    "auto_init": true,
    "has_issues": true,
    "has_projects": true,
    "has_wiki": false,
    "delete_branch_on_merge": true
}
EOF
)
    gh_api_call "POST" "/orgs/${ORG_NAME}/repos" "$payload" "Création du repo ${repo_name}"
}

# ── Création d'une branche à partir de main ────────────────────────────────
create_branch() {
    local repo="$1"
    local branch="$2"

    # Récupérer le SHA de la branche par défaut (main)
    local sha
    sha="$(gh_api_call "GET" "/repos/${ORG_NAME}/${repo}/git/ref/heads/main" "" "SHA main de ${repo}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['object']['sha'])" 2>/dev/null)" || return 1

    local payload="{\"ref\":\"refs/heads/${branch}\",\"sha\":\"${sha}\"}"
    gh_api_call "POST" "/repos/${ORG_NAME}/${repo}/git/refs" "$payload" "Branche ${branch} sur ${repo}" >/dev/null
}

# ── Protection de branche (minimale, sans required checks) ─────────────────
protect_branch_minimal() {
    local repo="$1"
    local branch="$2"

    local payload
    payload=$(cat <<EOF
{
    "required_pull_request_reviews": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews": true
    },
    "enforce_admins": false,
    "required_status_checks": null,
    "restrictions": null
}
EOF
)
    gh_api_call "PUT" "/repos/${ORG_NAME}/${repo}/branches/${branch}/protection" \
        "$payload" "Protection minimale ${branch} sur ${repo}" >/dev/null
}

# ── Ajout d'un fichier dans un dépôt ──────────────────────────────────────
add_file_to_repo() {
    local repo="$1"
    local file_path="$2"
    local content_base64="$3"
    local message="${4:-Add ${file_path}}"
    local branch="${5:-main}"

    local payload
    payload=$(cat <<EOF
{
    "message": "${message}",
    "content": "${content_base64}",
    "branch": "${branch}"
}
EOF
)
    gh_api_call "PUT" "/repos/${ORG_NAME}/${repo}/contents/${file_path}" \
        "$payload" "Fichier ${file_path} dans ${repo}" >/dev/null
}

# ── Pause pour rate limit ──────────────────────────────────────────────────
rate_limit_pause() {
    local delay="${1:-1}"
    sleep "$delay"
}

# ── Liste de tous les repos de l'organisation ──────────────────────────────
list_org_repos() {
    local page=1
    local all_repos=""
    while true; do
        local response
        response="$(gh_api_call "GET" "/orgs/${ORG_NAME}/repos?per_page=100&page=${page}" "" "Liste repos page ${page}")" || break
        local names
        names="$(echo "$response" | python3 -c "
import sys, json
repos = json.load(sys.stdin)
if not repos:
    sys.exit(0)
for r in repos:
    print(r['name'])
" 2>/dev/null)"
        if [[ -z "$names" ]]; then
            break
        fi
        all_repos+="${names}"$'\n'
        page=$((page + 1))
    done
    echo "$all_repos" | sed '/^$/d'
}

# ── Définition de la structure de l'organisation ───────────────────────────
# Format : GROUP/SUBGROUP/REPO_NAME DESCRIPTION
# Le nom du repo créé dans GitHub suit le pattern : group-subgroup-reponame
# (GitHub Orgs n'a pas de sous-groupes natifs, on utilise des préfixes)
declare -a REPO_DEFINITIONS=(
    # ── easytalk ──
    "easytalk/SupervisorAgent|Agent superviseur A2A EasyTalk"
    "easytalk/SearchAgent|Agent de recherche A2A EasyTalk"
    "easytalk/IntentAgent|Agent de détection d'intention EasyTalk"
    "easytalk/DataModel|Modèles de données partagés EasyTalk"

    # ── universes / telco ──
    "universes/telco/PassAgent|Agent gestion de forfaits télécom"
    "universes/telco/SubscriptionAgent|Agent gestion abonnements télécom"

    # ── universes / money ──
    "universes/money/TransferAgent|Agent de transfert d'argent"
    "universes/money/PaymentAgent|Agent de paiement"
    "universes/money/WalletAgent|Agent de portefeuille électronique"

    # ── universes / tv ──
    "universes/tv/ProgramAgent|Agent programmation TV"

    # ── aagate (gouvernance agentic) ──
    "aagate/ComplianceAgent|Agent de conformité AAGATE"
    "aagate/GoverningOrchestratorAgent|Orchestrateur de gouvernance AAGATE"
    "aagate/ShadowMonitorAgent|Agent de monitoring shadow AAGATE"
    "aagate/OpenPolicyAgent|Moteur OPA / règles Rego AAGATE"

    # ── a2a (agents for A2A protocol) ──
    "a2a/RegistryAgent|Registre d'agents A2A"
    "a2a/NamingSpaceAgent|Agent de gestion des espaces de nommage A2A"

    
    # ── cloudinfra ──
    "cloudinfra/istio-config|Configuration Istio et maillage réseau"
    "cloudinfra/s3|Implementation du stockage S3"
    "cloudinfra/kafka|Implemenation Apache Kafka"
    "cloudinfra/reddisStream|Implemenation Reddis Stream"
    "cloudinfra/reddis|Implemenation du cahe Reddis"

    # ── cicdtemplates ──
    "cicdtemplates/ci-templates|Templates CI partagés"
    "cicdtemplates/security-pipelines|Pipelines de sécurité partagés"
    "cicdtemplates/helm-charts|Charts Helm partagés"
    "cicdtemplates/qa-templates|Templates QA partagés"

    # ── nlp ──
    "nlp/WolofEnabler|Module NLP Wolof"
)

# Convertit un chemin group/subgroup/repo en nom de repo GitHub
path_to_repo_name() {
    local path="$1"
    echo "$path" | tr '/' '-'
}

# Extrait le groupe racine d'un chemin
path_to_group() {
    local path="$1"
    echo "$path" | cut -d'/' -f1
}

# ── Les branches protégées ─────────────────────────────────────────────────
PROTECTED_BRANCHES=("develop" "staging")
