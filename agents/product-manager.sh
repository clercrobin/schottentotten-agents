#!/bin/bash
# ============================================================
# 📊 Product Manager Agent — Stateful version
#
# intake:          Reads GitHub Issues + Discussion Ideas → creates state files
# check-decisions: Reads Q&A replies → merges to prod on approval
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_AGENT_MODE="${1:-}"
set --
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"
source "$SCRIPT_DIR/../lib/feature-state.sh"

MODE="${_AGENT_MODE:-intake}"
AGENT="product-manager"

log() { echo "[$(date '+%H:%M:%S')] [PM] $*"; }

run_intake() {
    log "📊 Collecting feature requests..."

    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"

    # GitHub Issues
    # GitHub Issues on the target project (schottentotten)
    local issues
    issues=$(gh issue list --repo "$target_repo" --state open --json number,title,labels --limit 10 2>/dev/null || echo "[]")
    local issue_count
    issue_count=$(echo "$issues" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    log "  Issues: $issue_count"

    # Create features from issues
    echo "$issues" | python3 -c "
import sys, json
for i in json.load(sys.stdin):
    labels = [l['name'] for l in i.get('labels', [])]
    crit = 'critical' if 'bug' in labels else 'high' if 'enhancement' in labels else 'medium'
    print(f\"{i['number']}\t{i['title']}\t{crit}\")
" 2>/dev/null | while IFS=$'\t' read -r inum ititle icrit; do
        [ -z "$inum" ] && continue
        # Use "i-" prefix to avoid ID collision with Discussion numbers
        local fid="i-${inum}"
        [ -f "$_FEATURE_DIR/${fid}.json" ] && continue

        log "  New issue: #$inum $ititle ($icrit)"
        feature_create "$fid" "$ititle" "$icrit"
        # Comment on the issue to confirm tracking
        gh issue comment "$inum" --repo "$target_repo" --body "📊 **Tracked by Agent Factory.** Agents will plan and implement this." 2>/dev/null || true
        log "  ✅ Feature $fid created from issue #$inum"
    done

    # Discussion Ideas (no env filter — human posts)
    local ideas
    ideas=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        discussions(first: 10, states: OPEN, orderBy: {field: CREATED_AT, direction: DESC}) {
          nodes { number title body category { name } }
        }
      }
    }' --jq '[.data.repository.discussions.nodes[] | select(.category.name == "Ideas")]' 2>/dev/null || echo "[]")

    printf '%s' "$ideas" | python3 -c "
import sys, json
for d in json.loads(sys.stdin.read()):
    print(f\"{d['number']}\t{d['title']}\")
" 2>/dev/null | while IFS=$'\t' read -r idea_num idea_title; do
        [ -z "$idea_num" ] && continue
        [ -f "$_FEATURE_DIR/${idea_num}.json" ] && continue

        log "  New: #$idea_num $idea_title"
        feature_create "$idea_num" "$idea_title" "medium" "$idea_num"
        reply_to_discussion "$idea_num" "📊 **Tracked.** Agents will plan and implement this." "$AGENT_PM" 2>/dev/null || true
        log "  ✅ Feature #$idea_num created"
    done
}

run_check_decisions() {
    log "📊 Checking for human decisions..."

    local qa_raw
    qa_raw=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        discussions(first: 5, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes { number title comments(last: 3) { nodes { body } } category { name } }
        }
      }
    }' --jq '.data.repository.discussions.nodes' 2>/dev/null || echo "[]")

    printf '%s' "$qa_raw" | python3 -c "
import sys, json
raw = sys.stdin.read().translate({i: None for i in range(32) if i not in (9, 10, 13)})
try:
    for d in json.loads(raw):
        if d.get('category', {}).get('name') != 'Q&A': continue
        if 'Ready for prod' not in d.get('title', ''): continue
        for c in d.get('comments', {}).get('nodes', []):
            if 'approve' in c['body'].lower() and 'Agent' not in c['body'][:20]:
                print(d['number'])
                break
except: pass
" 2>/dev/null | while read -r num; do
        [ -z "$num" ] && continue
        is_processed "$num" "$AGENT" "prod-actioned" && continue

        log "🚀 Approved — merging staging → main"
        cd "$TARGET_PROJECT"
        git fetch origin 2>/dev/null
        git checkout main 2>/dev/null
        git pull origin main 2>/dev/null
        if git merge "origin/${DEPLOY_BRANCH:-staging}" --no-edit -m "release: approved in Q&A #$num" 2>/dev/null; then
            git push origin main 2>&1 | tail -1
            reply_to_discussion "$num" "✅ **Shipped.**" "$AGENT_PM" 2>/dev/null || true
            log "✅ Merged"
        else
            git merge --abort 2>/dev/null
            log "⚠️ Conflict"
        fi
        git checkout "${DEPLOY_BRANCH:-staging}" 2>/dev/null
        mark_processed "$num" "$AGENT" "prod-actioned"
    done
}

# ────────────────────────────────────────────
# check-feedback — Scan feature discussions for new human comments
#
# For each active feature with a discussion, check if the human
# posted a reply AFTER the last agent reply. If so, treat it as
# feedback and reset the feature to triage for re-iteration.
# ────────────────────────────────────────────
run_check_feedback() {
    log "📊 Checking for human feedback on features..."

    local agents_repo="${GITHUB_OWNER}/${GITHUB_REPO}"

    # Iterate over all feature state files
    for f in "$_FEATURE_DIR"/*.json; do
        [ -e "$f" ] || continue

        local fid status disc_num last_feedback_ts
        fid=$(python3 -c "import json; d=json.load(open('$f')); print(d['id'])")
        status=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('status',''))")
        disc_num=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('discussion') or '')")

        # Skip features without discussions, or already done/triage
        [ -z "$disc_num" ] || [ "$disc_num" = "None" ] && continue
        [ "$status" = "done" ] || [ "$status" = "triage" ] && continue

        # Get last feedback timestamp from state (to avoid re-processing)
        last_feedback_ts=$(python3 -c "
import json
d = json.load(open('$f'))
fbs = [fb['at'] for fb in d.get('feedback', []) if fb.get('by') == 'human']
print(fbs[-1] if fbs else '')
" 2>/dev/null)

        # Fetch discussion comments
        local human_comment
        human_comment=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -F num="$disc_num" -f query='
        query($owner: String!, $repo: String!, $num: Int!) {
          repository(owner: $owner, name: $repo) {
            discussion(number: $num) {
              comments(last: 10) {
                nodes { body createdAt author { login } }
              }
            }
          }
        }' --jq '.data.repository.discussion.comments.nodes' 2>/dev/null || echo "[]")

        # Find human comments that are newer than last processed feedback
        local new_feedback
        new_feedback=$(printf '%s' "$human_comment" | python3 -c "
import sys, json
from datetime import datetime, timezone

last_ts = '$last_feedback_ts'
comments = json.loads(sys.stdin.read())

for c in comments:
    # Skip agent comments (they contain Agent markers)
    body = c.get('body', '')
    if any(marker in body[:50] for marker in ['[🤖', '[engineer]', '[reviewer]', '[planner]', 'Agent', '📋 **', '👷 **', '🔎 **', '✅ **', '📊 **']):
        continue

    # Skip if older than last processed feedback
    if last_ts and c['createdAt'] <= last_ts:
        continue

    # This is new human feedback
    # Clean up the body (first 300 chars)
    note = body.strip()[:300]
    print(json.dumps({'ts': c['createdAt'], 'note': note}))
" 2>/dev/null)

        [ -z "$new_feedback" ] && continue

        # Process each new human comment as feedback
        echo "$new_feedback" | while IFS= read -r fb_json; do
            [ -z "$fb_json" ] && continue

            local fb_note fb_ts
            fb_note=$(echo "$fb_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['note'])")
            fb_ts=$(echo "$fb_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['ts'])")

            log "  💬 #$fid: Human feedback on Discussion #$disc_num"
            log "     $fb_note"

            # Add feedback to state
            feature_add_feedback "$fid" "human" "reject" "$fb_note"

            # Clean up: close stale PR, delete branch/worktree
            local old_pr old_branch target_repo
            old_pr=$(feature_field "$fid" "pr")
            old_branch=$(feature_field "$fid" "branch")
            target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"

            [ -n "$old_pr" ] && [ "$old_pr" != "None" ] && \
                gh pr close "$old_pr" --repo "$target_repo" --delete-branch 2>/dev/null || true
            [ -n "$old_branch" ] && [ "$old_branch" != "None" ] && [ "$old_branch" != "staging" ] && {
                cd "$TARGET_PROJECT"
                local wt_dir="/tmp/agent-wt-${fid}"
                [ -d "$wt_dir" ] && git worktree remove "$wt_dir" --force 2>/dev/null || true
                git branch -D "$old_branch" 2>/dev/null || true
                git push origin --delete "$old_branch" 2>/dev/null || true
            }

            # Reset state for re-iteration
            feature_set "$fid" "branch" ""
            feature_set "$fid" "pr" ""
            feature_set_status "$fid" "triage"

            # Acknowledge on the discussion
            reply_to_discussion "$disc_num" \
                "📊 **Feedback received.** Resetting feature for re-iteration." \
                "$AGENT_PM" 2>/dev/null || true

            log "  ✅ #$fid reset to triage"
        done
    done
}

case "$MODE" in
    intake)          run_intake ;;
    check-decisions) run_check_decisions ;;
    check-feedback)  run_check_feedback ;;
    *)               echo "Usage: $0 {intake|check-decisions|check-feedback}"; exit 1 ;;
esac
