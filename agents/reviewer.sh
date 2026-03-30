#!/bin/bash
# ============================================================
# 🔎 Code Reviewer Agent — robust version (bash 3.2 compatible)
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-review}"
AGENT="reviewer"

log() { echo "[$(date '+%H:%M:%S')] [REV] $*"; }

run_review() {
    log "🔎 Looking for PRs to review..."

    local unprocessed
    unprocessed=$(get_unprocessed "$CAT_CODE_REVIEW" "$AGENT_REVIEWER") || return 0

    # Tab-separated output from Python — safe delimiter
    echo "$unprocessed" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    title = d['title'].replace('\t', ' ')
    body = d['body'][:2000].replace('\t', ' ')
    print(f\"{d['number']}\t{title}\t{body}\")
" 2>/dev/null | while IFS=$'\t' read -r num title body; do
        [ -z "$num" ] && continue

        is_processed "$num" "$AGENT" "reviewed" && continue

        log "Reviewing #$num: $title"

        # Extract branch name and PR number (BSD-compatible sed)
        local branch_name diff_content=""
        branch_name=$(echo "$body" | sed -n 's/.*Branch:[[:space:]]*`\([^`]*\)`.*/\1/p' | head -1)

        if [ -n "$branch_name" ]; then
            cd "$TARGET_PROJECT"
            git fetch origin 2>/dev/null || true
            local base_branch
            base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || echo "main")
            diff_content=$(git diff "$base_branch"..."origin/$branch_name" 2>/dev/null || echo "(could not get diff)")
        fi

        local pr_number
        pr_number=$(echo "$body" | sed -n 's|.*pull/\([0-9]*\).*|\1|p' | head -1)
        if [ -n "$pr_number" ] && { [ -z "$diff_content" ] || [ "$diff_content" = "(could not get diff)" ]; }; then
            diff_content=$(gh pr diff "$pr_number" --repo "$GITHUB_REPO_FULL" 2>/dev/null || echo "$diff_content")
        fi

        # Truncate diff to avoid token explosion
        diff_content="${diff_content:0:8000}"

        local review_prompt
        review_prompt=$(load_prompt "reviewer-review") || continue
        review_prompt=$(render_prompt "$review_prompt" \
            TITLE "$title" \
            BODY "$body" \
            DIFF_CONTENT "$diff_content")

        local review_result
        review_result=$(safe_claude "$AGENT" "$review_prompt" \
        --allowedTools "Bash,Read,Glob,Grep") || continue

        reply_to_discussion "$num" "$review_result" "$AGENT_REVIEWER" || continue

        if echo "$review_result" | grep -qi "APPROVED"; then
            tag_discussion "$num" "approved" || true
            log "✅ Approved #$num"
        else
            tag_discussion "$num" "changes-requested" || true
            log "🔄 Changes requested #$num"
        fi

        mark_processed "$num" "$AGENT" "reviewed"
    done
}

case "$MODE" in
    review) run_review ;;
    *)      echo "Usage: $0 {review}"; exit 1 ;;
esac
