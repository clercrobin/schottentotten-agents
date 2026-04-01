#!/bin/bash
# ============================================================
# 📦 Release Pipeline — Global, site-level
#
# Checks staging for unreleased changes.
# If CI + smoke green → posts Q&A with changelog for approval.
# PM handles the approval → merge to main.
#
# Usage:
#   ./pipelines/release.sh --project foo --env staging
#   ./pipelines/release.sh --project foo --env staging --loop
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
_AGENT_MODE="${1:-}"
set --
source "$SCRIPT_DIR/config-loader.sh"
eval "$(parse_project_flag "$@")"
eval "$(parse_env_flag "$@")"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/feature-state.sh"
source "$SCRIPT_DIR/lib/discussions.sh"

ACTION="${_AGENT_MODE:-}"
log() { echo "[$(date '+%H:%M:%S')] [REL] $*"; }

# Release always goes from DEPLOY_BRANCH (staging) → main
check_release() {
    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
    local from_branch="${DEPLOY_BRANCH:-staging}"
    local to_branch="main"

    log "Checking: $from_branch → $to_branch"

    cd "$TARGET_PROJECT"
    git fetch origin 2>/dev/null || true

    # Ahead count
    local ahead
    ahead=$(git rev-list --count "origin/main..origin/$from_branch" 2>/dev/null || echo "0")

    if [ "$ahead" -eq 0 ]; then
        log "Staging = main. Nothing to release."
        return 0
    fi

    log "Staging: +$ahead commits"

    # CI status
    local ci_status
    ci_status=$(gh run list --repo "$target_repo" --branch "$from_branch" --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "unknown")

    if [ "$ci_status" != "success" ]; then
        log "CI: $ci_status — not ready"
        return 0
    fi

    # Pending approval check
    local pending
    pending=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        discussions(first: 5, states: OPEN) {
          nodes { title category { name } }
        }
      }
    }' --jq '[.data.repository.discussions.nodes[] | select(.category.name == "Q&A") | select(.title | contains("Ready for prod"))] | length' 2>/dev/null || echo "0")

    if [ "$pending" -gt 0 ]; then
        log "Approval already pending"
        return 0
    fi

    # Build changelog
    local changelog staging_sha
    changelog=$(git log --oneline "origin/main..origin/$from_branch" --no-merges 2>/dev/null | head -20)
    staging_sha=$(git rev-parse --short "origin/$from_branch" 2>/dev/null)

    local features
    features=$(feature_list 2>/dev/null | grep -E "done|reviewed" || echo "(none)")

    # Health
    local health="?"
    if [ -n "${DEPLOY_URL:-}" ]; then
        health="HTTP $(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "$DEPLOY_URL" 2>/dev/null || echo '000')"
    fi

    log "✅ Posting release approval"

    post_discussion "Q&A" "🚀 Ready for prod — \`$staging_sha\`" \
"**@${GITHUB_OWNER}** — Staging is green.

## What's in this release ($ahead changes)

### Features
\`\`\`
$features
\`\`\`

### Commits
\`\`\`
$changelog
\`\`\`

## Gates
| CI | ✅ $ci_status |
| Health | $health |
| Staging | ${DEPLOY_URL:-N/A} |

---
Reply **approve** to ship." "📦 Release Pipeline" || true
}

case "$ACTION" in
    --loop)
        log "🔁 Release loop — checks every 5 min"
        trap 'log "🛑 Stopping"; exit 0' INT TERM
        while true; do
            check_release
            sleep 300
        done
        ;;
    *)
        check_release
        ;;
esac
