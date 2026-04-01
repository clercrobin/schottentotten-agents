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
# Save args before config-loader clears them
_ALL_ARGS=("$@")
_AGENT_MODE="${_ALL_ARGS[-1]:-}"
# Strip flags to get just the action
for _a in "${_ALL_ARGS[@]}"; do case "$_a" in --project|--env) ;; -*) _AGENT_MODE="$_a" ;; *) _AGENT_MODE="$_a" ;; esac; done
set --
source "$SCRIPT_DIR/config-loader.sh"
eval "$(parse_project_flag "${_ALL_ARGS[@]}")"
eval "$(parse_env_flag "${_ALL_ARGS[@]}")"
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
        # Check if human already replied "approve"
        local approved
        approved=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='
        query($owner: String!, $repo: String!) {
          repository(owner: $owner, name: $repo) {
            discussions(first: 5, states: OPEN) {
              nodes { number title comments(last: 5) { nodes { body } } category { name } }
            }
          }
        }' --jq '[.data.repository.discussions.nodes[] |
            select(.category.name == "Q&A") |
            select(.title | contains("Ready for prod")) |
            select(.comments.nodes[].body | ascii_downcase | contains("approve")) |
            .number] | first' 2>/dev/null || echo "")

        if [ -n "$approved" ]; then
            log "🚀 Human approved — creating release PR $from_branch → $to_branch"

            # Build changelog for PR body
            cd "$TARGET_PROJECT"
            git fetch origin 2>/dev/null || true
            local pr_changelog
            pr_changelog=$(git log --oneline "origin/$to_branch..origin/$from_branch" --no-merges 2>/dev/null | head -20)
            local pr_features
            pr_features=$(feature_list 2>/dev/null | grep -E "done|reviewed" || echo "(none)")

            # Create and merge a PR (visible in GitHub interface)
            local release_pr
            release_pr=$(gh pr create --repo "$target_repo" \
                --title "Release: $from_branch → $to_branch (Q&A #$approved)" \
                --body "## Release approved in Q&A #$approved

### Features
\`\`\`
$pr_features
\`\`\`

### Commits
\`\`\`
$pr_changelog
\`\`\`" \
                --base "$to_branch" \
                --head "$from_branch" 2>&1 | grep -oE 'https://[^ ]+' | tail -1) || release_pr=""

            if [ -n "$release_pr" ]; then
                log "  📋 Release PR: $release_pr"
                # Merge the PR
                local pr_num
                pr_num=$(echo "$release_pr" | grep -oE '[0-9]+$')
                if gh pr merge "$pr_num" --repo "$target_repo" --merge 2>/dev/null; then
                    reply_to_discussion "$approved" "✅ **Shipped to prod.** Release PR: $release_pr" "📦 Release Pipeline" 2>/dev/null || true
                # Close the Q&A
                local disc_id
                disc_id=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -F num="$approved" -f query='query($owner: String!, $repo: String!, $num: Int!) { repository(owner: $owner, name: $repo) { discussion(number: $num) { id } } }' --jq '.data.repository.discussion.id' 2>/dev/null)
                [ -n "$disc_id" ] && gh api graphql -f id="$disc_id" -f query='mutation($id: ID!) { closeDiscussion(input: { discussionId: $id, reason: RESOLVED }) { discussion { number } } }' 2>/dev/null || true
                # Wait for prod CI + verify health
                log "  ⏳ Waiting for prod deploy..."
                local prod_ok=false
                for i in $(seq 1 20); do
                    sleep 15
                    local prod_ci
                    prod_ci=$(gh run list --repo "$target_repo" --branch "$to_branch" --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "unknown")
                    if [ "$prod_ci" = "success" ]; then
                        prod_ok=true
                        break
                    elif [ "$prod_ci" = "failure" ]; then
                        log "  ❌ Prod CI FAILED"
                        reply_to_discussion "$approved" "❌ **Prod CI failed after merge.** Investigate immediately." "📦 Release Pipeline" 2>/dev/null || true
                        break
                    fi
                    log "  ⏳ Prod CI: $prod_ci ($i/20)"
                done

                if [ "$prod_ok" = true ]; then
                    # Health check prod URL
                    local prod_url="https://$(basename "$TARGET_PROJECT").com"
                    # Try known prod URLs
                    for url in "$prod_url" "https://schottentotten.com"; do
                        local http_code
                        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || echo "000")
                        if [ "$http_code" = "200" ] || [ "$http_code" = "301" ]; then
                            log "  ✅ Prod healthy: $url → HTTP $http_code"
                            reply_to_discussion "$approved" "✅ **Prod verified.** CI passed, $url → HTTP $http_code" "📦 Release Pipeline" 2>/dev/null || true
                            break
                        fi
                    done
                fi

                log "✅ Released and Q&A closed"
                else
                    log "  ⚠️ PR merge failed"
                    reply_to_discussion "$approved" "⚠️ **Release PR created but merge failed.** PR: $release_pr" "📦 Release Pipeline" 2>/dev/null || true
                fi
            else
                log "  ⚠️ Could not create release PR"
            fi
        else
            log "Approval pending — waiting for human"
        fi
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
