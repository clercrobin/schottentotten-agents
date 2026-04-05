#!/bin/bash
# ============================================================
# 🔎 Code Reviewer Agent — Stateful version
#
# Receives feature ID. Reads state for PR number.
# Reviews via gh pr diff. Updates state.
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

FEATURE_ID="${_AGENT_MODE:-}"
AGENT="reviewer"
log() { echo "[$(date '+%H:%M:%S')] [REV] $*"; }

[ -z "$FEATURE_ID" ] && { log "No feature ID"; exit 1; }

topic=$(feature_field "$FEATURE_ID" "topic")
pr_num=$(feature_field "$FEATURE_ID" "pr")
discussion=$(feature_field "$FEATURE_ID" "discussion")

[ -z "$pr_num" ] || [ "$pr_num" = "None" ] && { log "No PR for #$FEATURE_ID"; exit 0; }

log "🔎 Reviewing #$FEATURE_ID: $topic (PR #$pr_num)"

target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"

# Get diff directly — no Discussion parsing
full_diff=$(gh pr diff "$pr_num" --repo "$target_repo" 2>/dev/null)
full_diff_len=${#full_diff}
diff_content=$(echo "$full_diff" | head -c 30000)
# If truncated, note which files are in the full diff
if [ "$full_diff_len" -gt 30000 ]; then
    diff_files=$(echo "$full_diff" | grep '^diff --git' | sed 's|diff --git a/||;s| b/.*||')
    diff_content="$diff_content

--- DIFF TRUNCATED ($full_diff_len chars) ---
Full file list: $diff_files"
fi

[ -z "$diff_content" ] && { log "No diff for PR #$pr_num"; exit 0; }

log "  Diff: ${#diff_content} chars"

# Dynamic context — reviewer agent definition provides system prompt
review_prompt="## PR: $topic

## Context:
Feature #$FEATURE_ID — $topic

## Diff:
\`\`\`diff
$diff_content
\`\`\`

Review this PR. Start with **APPROVED** or **CHANGES REQUESTED**."

review_result=$(safe_claude "reviewer" "$review_prompt") || exit 1

# Post review as PR comment
gh pr comment "$pr_num" --repo "$target_repo" --body "$review_result" 2>/dev/null || true

# Update state based on verdict
if echo "$review_result" | grep -qi "APPROVED"; then
    feature_set_status "$FEATURE_ID" "reviewed"
    feature_set "$FEATURE_ID" "review_verdict" "approved"
    [ -n "$discussion" ] && [ "$discussion" != "null" ] && \
        reply_to_discussion "$discussion" "🔎 **APPROVED.** Ready to merge." "$AGENT" 2>/dev/null || true
    log "✅ Approved #$FEATURE_ID"
else
    note=""
    note=$(echo "$review_result" | grep -i "P1\|must fix\|CHANGES" | head -3 | tr '\n' ' ')
    feature_add_feedback "$FEATURE_ID" "reviewer" "changes-requested" "$note"

    # Track reviewer rejection count for model escalation
    python3 -c "
import json, os
path = os.path.join('${_FEATURE_DIR}', '${FEATURE_ID}.json')
d = json.load(open(path))
rc = len([fb for fb in d.get('feedback', []) if fb.get('by') == 'reviewer'])
if rc >= 3 and not d.get('model'):
    d['model'] = 'opus'
    print(f'ESCALATE to opus after {rc} reviewer rejections')
json.dump(d, open(path, 'w'), indent=2)
" 2>/dev/null | while read -r msg; do log "  🔺 $msg"; done
    feature_set_status "$FEATURE_ID" "building"  # send back to engineer
    [ -n "$discussion" ] && [ "$discussion" != "null" ] && \
        reply_to_discussion "$discussion" "🔄 **Changes requested.** Engineer will fix." "$AGENT" 2>/dev/null || true
    log "🔄 Changes requested #$FEATURE_ID → back to building"
fi
