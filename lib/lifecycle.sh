#!/bin/bash
# ============================================================
# Feature lifecycle helpers
#
# Each feature/bug gets ONE discussion. Its title tracks status:
#   [staging] [TRIAGE] Fix applyMove exception
#   [staging] [PLANNING] Fix applyMove exception
#   [staging] [BUILDING] Fix applyMove exception
#   [staging] [REVIEW] Fix applyMove exception
#   [staging] [APPROVED] Fix applyMove exception
#   [staging] [DONE] Fix applyMove exception
#
# Agents reply to the original discussion and update the title.
# ============================================================

source "$(dirname "${BASH_SOURCE[0]}")/discussions.sh"

# Statuses in lifecycle order
# TRIAGE → PLANNING → BUILDING → REVIEW → APPROVED → DONE
# Also: SECURITY-BLOCKED, CHANGES-REQUESTED

# ────────────────────────────────────────────
# Create a new triage item with [TRIAGE] status
# Usage: create_triage "title" "body" "agent-label"
# Returns: discussion number
# ────────────────────────────────────────────
create_triage() {
    local title="$1"
    local body="$2"
    local agent_label="$3"

    # post_discussion already adds [env] prefix
    local disc_num
    disc_num=$(post_discussion "$CAT_TRIAGE" "[TRIAGE] $title" "$body" "$agent_label") || return 1
    echo "$disc_num"
}

# ────────────────────────────────────────────
# Advance a discussion to the next lifecycle status
# Also replies with context about what happened
# Usage: advance_status <disc_num> "NEW_STATUS" "topic" "comment" "agent-label"
# ────────────────────────────────────────────
advance_status() {
    local disc_num="$1"
    local new_status="$2"
    local topic="$3"
    local comment="$4"
    local agent_label="${5:-system}"

    update_status "$disc_num" "$new_status" "$topic" 2>/dev/null || true
    reply_to_discussion "$disc_num" "**→ $new_status**

$comment" "$agent_label" || true
}

# ────────────────────────────────────────────
# Extract the topic from a discussion title
# "[staging] [TRIAGE] Fix applyMove exception" → "Fix applyMove exception"
# ────────────────────────────────────────────
extract_topic() {
    local title="$1"
    echo "$title" | sed 's/\[[^]]*\] *//g' | sed 's/^ *//'
}
