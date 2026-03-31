#!/bin/bash
# ============================================================
# 🔎 Code Reviewer Agent — Single comprehensive review
#
# ONE Claude session covering all 7 domains:
# security, performance, architecture, data integrity,
# code quality, deployment safety, test coverage.
#
# Previous design: 7 specialist sessions + 1 synthesis = 8 sessions
# Current design: 1 comprehensive session = 1 session (8x faster)
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/lifecycle.sh" 2>/dev/null || true
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-review}"
AGENT="reviewer"

log() { echo "[$(date '+%H:%M:%S')] [REV] $*"; }

run_review() {
    log "🔎 Looking for PRs to review..."

    local unprocessed
    # Look for [REVIEW] items across ALL open discussions (any category)
    unprocessed=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='query($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { discussions(first: 20, states: OPEN) { nodes { number title body comments(first:3) { nodes { body } } } } } }' --jq '.data.repository.discussions.nodes' 2>/dev/null | python3 -c "
import sys, json
raw = sys.stdin.read().translate({i: None for i in range(32) if i not in (9, 10, 13)})
try:
    for d in json.loads(raw):
        if '[REVIEW]' in d.get('title', ''):
            print(json.dumps(d))
except: pass
" 2>/dev/null)
    [ -z "$unprocessed" ] && { log "No PRs to review."; return 0; }
    # Wrap back into JSON array for the downstream parser
    unprocessed="[$(echo "$unprocessed" | paste -sd ',' -)]"

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

        # Get diff
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

        diff_content="${diff_content:0:12000}"

        # ONE comprehensive review — all 7 domains in a single session
        local review_prompt
        review_prompt=$(load_prompt "reviewer-comprehensive") || continue
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

            # Write P1/P2 findings to todos/
            local todos_dir="$TARGET_PROJECT/todos"
            if [ -d "$todos_dir" ]; then
                local todo_count next_num safe_title
                todo_count=$(ls "$todos_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')
                next_num=$(printf "%03d" $((todo_count + 1)))
                safe_title=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 40)

                echo "$review_result" | python3 -c "
import sys, os
review = sys.stdin.read()
todos_dir = '$todos_dir'
num = int('$next_num')
safe_title = '$safe_title'
lines = review.split('\n')
current_priority = None
findings = []
for line in lines:
    if 'P1' in line and ('Must Fix' in line or 'CRITICAL' in line.upper()):
        current_priority = 'p1'
    elif 'P2' in line and ('Should Fix' in line or 'IMPORTANT' in line.upper()):
        current_priority = 'p2'
    elif 'P3' in line or '###' in line:
        current_priority = None
    elif current_priority and line.strip().startswith('- '):
        findings.append((current_priority, line.strip()))
for i, (priority, finding) in enumerate(findings):
    todo_num = f'{num + i:03d}'
    status = 'ready' if priority == 'p1' else 'pending'
    fname = f'{todo_num}-{status}-{priority}-{safe_title}.md'
    with open(os.path.join(todos_dir, fname), 'w') as f:
        f.write(f'---\nstatus: {status}\npriority: {priority}\nsource: code-review\n---\n\n{finding}\n')
" 2>/dev/null || true
            fi
        fi

        mark_processed "$num" "$AGENT" "reviewed"
    done
}

case "$MODE" in
    review) run_review ;;
    *)      echo "Usage: $0 {review}"; exit 1 ;;
esac
