#!/bin/bash
# ============================================================
# 🔧 DevOps Agent — Infrastructure & deployment management
#
# Handles:
# - Terraform plan/apply for infrastructure changes
# - Staging branch management (merge all PRs, push)
# - CI/CD pipeline health monitoring
# - Deployment verification
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-infra}"
AGENT="devops"

log() { echo "[$(date '+%H:%M:%S')] [OPS] $*"; }

# ────────────────────────────────────────────
# infra — Detect and apply infrastructure changes
# ────────────────────────────────────────────
run_infra() {
    log "🔧 Checking infrastructure [env=${ENV_NAME:-prod}, branch=${DEPLOY_BRANCH:-main}]..."

    cd "$TARGET_PROJECT"

    # Use env-specific TF directory if set, otherwise scan all
    local tf_dirs=()
    if [ -n "${TF_DIR:-}" ] && [ -d "$TARGET_PROJECT/$TF_DIR" ]; then
        tf_dirs=("$TF_DIR")
    else
        while IFS= read -r d; do
            tf_dirs+=("$d")
        done < <(find . -name "*.tf" -not -path "*/.*" -not -path "*/.terraform/*" -exec dirname {} \; 2>/dev/null | sort -u)
    fi

    if [ ${#tf_dirs[@]} -eq 0 ]; then
        log "  No Terraform files found"
        return 0
    fi

    log "  Found ${#tf_dirs[@]} Terraform directories (env: ${ENV_NAME:-prod})"

    local prompt_text
    prompt_text=$(load_prompt "devops-infra") || { log "Cannot load devops-infra prompt"; return 1; }

    local result
    result=$(safe_claude "$AGENT" "$prompt_text" \
    --allowedTools "Bash,Read,Glob,Grep") || {
        log "⚠️  Infra check failed"
        return 1
    }

    local result_len=${#result}
    if [ "$result_len" -lt 20 ]; then
        log "  No infra actions needed"
        return 0
    fi

    # Post findings
    post_discussion "$CAT_ENGINEERING" "🔧 Infrastructure: pending changes detected" \
"$result

---
*DevOps Agent — review and approve before applying.*" "$AGENT_DEVOPS" || true

    log "✅ Infra report posted"
}

# ────────────────────────────────────────────
# apply — Run terraform plan/apply on pending changes
# ────────────────────────────────────────────
run_apply() {
    log "🔧 Looking for approved infra changes to apply..."

    local unprocessed
    unprocessed=$(get_unprocessed "$CAT_ENGINEERING" "$AGENT_DEVOPS") || return 0

    echo "$unprocessed" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    comments = ' '.join(d.get('last_comments', []))
    is_infra = 'infrastructure' in d['title'].lower() or 'terraform' in d['title'].lower() or 'devops' in d['title'].lower()
    is_approved = 'APPROVED' in comments.upper() or 'apply' in comments.lower()
    if is_infra and is_approved:
        title = d['title'].replace('\t', ' ')
        body = d['body'][:3000].replace('\t', ' ')
        print(f\"{d['number']}\t{title}\t{body}\")
" 2>/dev/null | while IFS=$'\t' read -r num title body; do
        [ -z "$num" ] && continue

        is_processed "$num" "$AGENT" "applied" && continue

        log "🔧 Applying infra changes for #$num: $title"

        local apply_prompt
        apply_prompt=$(load_prompt "devops-apply") || continue
        apply_prompt=$(render_prompt "$apply_prompt" \
            TITLE "$title" \
            BODY "$body")

        local result
        result=$(safe_claude "$AGENT" "$apply_prompt" \
        --allowedTools "Bash,Read,Glob,Grep") || continue

        reply_to_discussion "$num" "🔧 **Infrastructure applied.**

$result" "$AGENT_DEVOPS" || true

        mark_processed "$num" "$AGENT" "applied"
        log "✅ Applied #$num"
    done
}

# ────────────────────────────────────────────
# staging — Rebuild staging branch from all open PRs
# ────────────────────────────────────────────
run_staging() {
    local target_branch="${DEPLOY_BRANCH:-staging}"
    if [ "$target_branch" = "main" ]; then
        log "🧪 Skipping staging rebuild (env=${ENV_NAME:-prod} deploys from main)"
        return 0
    fi

    # Staging is managed via GitHub PRs targeting the staging branch.
    # This agent does NOT rebuild staging from scratch every cycle.
    # It only logs the current state. Full rebuilds are manual operations.
    log "🧪 Staging status check [env=${ENV_NAME:-staging}]..."

    cd "$TARGET_PROJECT"
    git fetch origin 2>/dev/null || true

    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
    local open_prs
    open_prs=$(gh pr list --repo "$target_repo" --state open --base "$target_branch" --json number --jq 'length' 2>/dev/null || echo "0")
    log "  Open PRs targeting $target_branch: $open_prs"

    local base_branch
    base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || echo "main")
    local behind
    behind=$(git rev-list --count "origin/$target_branch..origin/$base_branch" 2>/dev/null || echo "?")
    local ahead
    ahead=$(git rev-list --count "origin/$base_branch..origin/$target_branch" 2>/dev/null || echo "?")
    log "  Staging vs main: +$ahead ahead, -$behind behind"

    # Post summary
    local summary="## Staging Branch Rebuilt

**Base:** \`$base_branch\`
**PRs merged:** $merged / $pr_count
**Conflicts:** $failed"

    if [ "$failed" -gt 0 ]; then
        summary="$summary

### Conflicting branches (need manual resolution):
$(echo -e "$conflict_branches")"
    fi

    post_discussion "$CAT_ENGINEERING" "🧪 [$ENV_NAME] Branch rebuilt — $merged/$pr_count PRs merged" \
"$summary

**Deploy URL:** ${DEPLOY_URL:-N/A}

---
*CI will deploy automatically on push to \`$target_branch\`.*" "$AGENT_DEVOPS" || true

    log "✅ $target_branch rebuilt and pushed ($merged/$pr_count)"
}

# ────────────────────────────────────────────
# ci-health — Check pipeline health
# ────────────────────────────────────────────
run_ci_health() {
    log "🔧 Checking CI/CD health..."

    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"

    # Check recent workflow runs
    local runs
    runs=$(gh run list --repo "$target_repo" --limit 10 --json databaseId,status,conclusion,name,headBranch,createdAt 2>/dev/null) || {
        log "  Cannot fetch workflow runs"
        return 0
    }

    local failed_runs
    failed_runs=$(echo "$runs" | python3 -c "
import sys, json
runs = json.load(sys.stdin)
failed = [r for r in runs if r.get('conclusion') == 'failure']
if failed:
    for r in failed[:3]:
        print(f\"- **{r['name']}** on \`{r['headBranch']}\` — {r['createdAt'][:10]}\")
" 2>/dev/null)

    if [ -n "$failed_runs" ]; then
        log "  ⚠️  Found failed CI runs"
        post_discussion "$CAT_ENGINEERING" "⚠️ CI/CD: Recent failures detected" \
"### Failed workflow runs:
$failed_runs

Please investigate and fix." "$AGENT_DEVOPS" || true
    else
        log "  ✅ CI/CD healthy"
    fi
}

# ────────────────────────────────────────────
# deploy-verify — Check that the deployment is healthy
# ────────────────────────────────────────────
run_deploy_verify() {
    log "🔧 Verifying deployment [env=${ENV_NAME:-prod}]..."

    if [ -z "${DEPLOY_URL:-}" ]; then
        log "  No DEPLOY_URL set for env ${ENV_NAME:-prod}, skipping"
        return 0
    fi

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "$DEPLOY_URL" 2>/dev/null || echo "000")

    if [ "$status" = "200" ] || [ "$status" = "301" ] || [ "$status" = "302" ]; then
        log "  ✅ ${ENV_NAME:-prod}: $DEPLOY_URL → HTTP $status"
    else
        log "  ❌ ${ENV_NAME:-prod}: $DEPLOY_URL → HTTP $status"
        post_discussion "$CAT_ENGINEERING" "❌ [${ENV_NAME:-prod}] Deploy verification failed" \
"**URL:** $DEPLOY_URL
**HTTP Status:** $status
**Branch:** ${DEPLOY_BRANCH:-main}

Deployment appears unhealthy. Investigate." "$AGENT_DEVOPS" || true
    fi
}

case "$MODE" in
    infra)         run_infra ;;
    apply)         run_apply ;;
    staging)       run_staging ;;
    ci-health)     run_ci_health ;;
    deploy-verify) run_deploy_verify ;;
    *)             echo "Usage: $0 {infra|apply|staging|ci-health|deploy-verify}"; exit 1 ;;
esac
