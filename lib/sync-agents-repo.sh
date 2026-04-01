#!/bin/bash
# ============================================================
# Sync feature status to the agents repo (schottentotten-agents)
#
# Posts/updates a pinned "Feature Board" discussion showing
# all active features and their status. Human-readable dashboard.
#
# Also ensures Discussion summaries are posted for key events.
# ============================================================

_SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ────────────────────────────────────────────
# Update the feature board in agents repo
# One discussion, updated with current status of all features
# ────────────────────────────────────────────
sync_feature_board() {
    local board_content
    board_content=$(python3 "$_SYNC_DIR/feature-state.py" list 2>/dev/null)

    [ -z "$board_content" ] && board_content="No features tracked."

    post_or_update "$CAT_ENGINEERING" "📋 Feature Board" \
"## Active Features

\`\`\`
$board_content
\`\`\`

*Updated $(date -u '+%Y-%m-%d %H:%M UTC')*" "🤖 Factory" 2>/dev/null || true
}

# ────────────────────────────────────────────
# Post a summary event to agents repo Discussion
# Usage: sync_event <feature_id> <event> <detail>
# ────────────────────────────────────────────
sync_event() {
    local fid="$1" event="$2" detail="${3:-}"
    local topic
    topic=$(FID="$fid" python3 "$_SYNC_DIR/feature-state.py" field 2>/dev/null <<< "" || echo "#$fid")
    # Only topic field
    FIELD="topic" topic=$(FID="$fid" FIELD="topic" python3 "$_SYNC_DIR/feature-state.py" field 2>/dev/null || echo "#$fid")

    local discussion
    discussion=$(FID="$fid" FIELD="discussion" python3 "$_SYNC_DIR/feature-state.py" field 2>/dev/null || echo "")

    # Post to the feature's Discussion if it has one
    if [ -n "$discussion" ] && [ "$discussion" != "None" ] && [ "$discussion" != "" ]; then
        reply_to_discussion "$discussion" "$event $detail" "🤖 Factory" 2>/dev/null || true
    fi
}
