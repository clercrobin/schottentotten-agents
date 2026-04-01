#!/bin/bash
# ============================================================
# 📦 Release Pipeline — Staging → Prod gate
#
# Runs periodically. Checks if staging has unreleased changes.
# If staging is green (CI + smoke), creates a release summary
# and posts Q&A for human approval.
#
# When human approves, PM merges staging → main.
#
# Usage:
#   ./release-pipeline.sh --project schottentotten --env staging
#   ./release-pipeline.sh --project schottentotten --env staging --loop
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config-loader.sh"
eval "$(parse_project_flag "$@")"
eval "$(parse_env_flag "$@")"

source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/feature-state.sh"
source "$SCRIPT_DIR/lib/discussions.sh"

ACTION="${1:-}"

log() { echo "[$(date '+%H:%M:%S')] [REL] $*"; }

# ────────────────────────────────────────────
# Check if staging has unreleased changes
# ────────────────────────────────────────────
check_release() {
    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
    local staging_branch="${DEPLOY_BRANCH:-staging}"

    cd "$TARGET_PROJECT"
    git fetch origin 2>/dev/null || true

    # Count commits on staging not on main
    local ahead
    ahead=$(git rev-list --count "origin/main..origin/$staging_branch" 2>/dev/null || echo "0")

    if [ "$ahead" -eq 0 ]; then
        log "Staging = main. Nothing to release."
        return 0
    fi

    log "Staging is $ahead commits ahead of main"

    # Check staging CI
    local ci_status
    ci_status=$(gh run list --repo "$target_repo" --branch "$staging_branch" --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "unknown")

    if [ "$ci_status" != "success" ]; then
        log "Staging CI: $ci_status — not ready for release"
        return 0
    fi

    # Check if there's already a pending approval
    local pending_approval
    pending_approval=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        discussions(first: 5, states: OPEN, orderBy: {field: CREATED_AT, direction: DESC}) {
          nodes { title category { name } }
        }
      }
    }' --jq '[.data.repository.discussions.nodes[] | select(.category.name == "Q&A") | select(.title | contains("Ready for prod"))] | length' 2>/dev/null || echo "0")

    if [ "$pending_approval" -gt 0 ]; then
        log "Release approval already pending — waiting for human"
        return 0
    fi

    # Build changelog
    local changelog
    changelog=$(git log --oneline "origin/main..origin/$staging_branch" --no-merges 2>/dev/null | head -20)
    local commit_count
    commit_count=$(echo "$changelog" | wc -l | tr -d ' ')
    local staging_sha
    staging_sha=$(git rev-parse --short "origin/$staging_branch" 2>/dev/null)

    # List done features
    local features_in_release
    features_in_release=$(feature_list 2>/dev/null | grep "done\|reviewed" || echo "(none tracked)")

    # Deploy URL health check
    local health="?"
    if [ -n "${DEPLOY_URL:-}" ]; then
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "$DEPLOY_URL" 2>/dev/null || echo "000")
        health="HTTP $http_code"
    fi

    log "✅ Staging ready — posting release approval"

    # Post Q&A with full changelog
    post_discussion "Q&A" "🚀 Ready for prod — \`$staging_sha\`" \
"**@${GITHUB_OWNER}** — Staging is green with $commit_count changes.

## What's in this release

### Features
\`\`\`
$features_in_release
\`\`\`

### Commits
\`\`\`
$changelog
\`\`\`

## Gates
| Gate | Status |
|------|--------|
| CI | ✅ $ci_status |
| Health | $health |
| Staging URL | ${DEPLOY_URL:-N/A} |

---
Reply **approve** to ship, **hold** to wait, **reject** to cancel." "📦 Release Pipeline" || true

    log "📦 Release approval posted"
}

# ────────────────────────────────────────────
# Main
# ────────────────────────────────────────────
case "$ACTION" in
    --loop)
        log "🔁 Release pipeline loop"
        trap 'log "🛑 Stopping"; exit 0' INT TERM
        while true; do
            check_release
            log "💤 Next check in 5 min"
            sleep 300
        done
        ;;
    --help|-h)
        echo "📦 Release Pipeline — Staging → Prod gate"
        echo ""
        echo "  ./release-pipeline.sh --project <name> --env <env>"
        echo "  ./release-pipeline.sh --project <name> --env <env> --loop"
        ;;
    *)
        check_release
        ;;
esac
