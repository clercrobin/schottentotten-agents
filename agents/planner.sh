#!/bin/bash
# ============================================================
# 📋 Planner Agent — Compound Engineering: Plan phase
#
# Researches the codebase, investigates patterns, and produces
# a detailed implementation plan BEFORE any code is written.
# Plans are posted to the Planning category for CTO approval.
#
# "Plans document decisions before they become bugs."
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/lifecycle.sh" 2>/dev/null || true
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-plan}"
AGENT="planner"

log() { echo "[$(date '+%H:%M:%S')] [PLAN] $*"; }

# ────────────────────────────────────────────
# plan — Pick up triaged issues, research, create implementation plan
# ────────────────────────────────────────────
run_plan() {
    log "📋 Looking for issues to plan..."

    # Use get_discussions and filter by [TRIAGE] status in title
    # (not get_unprocessed — agent replies shouldn't block re-planning)
    local all_triage
    all_triage=$(get_discussions "$CAT_TRIAGE" 20) || return 0

    local candidates
    candidates=$(echo "$all_triage" | python3 -c "
import sys, json, re
priority_order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
try:
    discussions = json.load(sys.stdin)
    # Only pick up items in [TRIAGE] status — not [APPROVED], [BUILDING], etc.
    discussions = [d for d in discussions if '[TRIAGE]' in d.get('title', '') or '[FEATURE]' in d.get('title', '')]
    def get_priority(d):
        m = re.search(r'\[(CRITICAL|HIGH|MEDIUM|LOW)\]', d.get('title', ''), re.IGNORECASE)
        return priority_order.get(m.group(1).lower(), 9) if m else 9
    discussions.sort(key=get_priority)
    for d in discussions:
        print(json.dumps(d))
except (json.JSONDecodeError, KeyError):
    pass
" 2>/dev/null)

    if [ -z "$candidates" ]; then
        log "No issues to plan."
        return 0
    fi

    local task_json="" task_num=""
    while IFS= read -r candidate; do
        [ -z "$candidate" ] && continue
        local cand_num
        cand_num=$(echo "$candidate" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin)['number'])
except (KeyError, json.JSONDecodeError):
    sys.exit(1)
" 2>/dev/null) || continue
        if ! is_processed "$cand_num" "$AGENT" "planned"; then
            task_json="$candidate"
            task_num="$cand_num"
            break
        fi
    done <<< "$candidates"

    if [ -z "$task_num" ]; then
        log "No unplanned issues."
        return 0
    fi

    local task_title task_body
    task_title=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])" 2>/dev/null) || return 1
    task_body=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])" 2>/dev/null) || task_body="(no body)"

    log "📋 Planning #$task_num: $task_title"

    reply_to_discussion "$task_num" "📋 **Planning started.** Researching codebase and designing implementation approach." "$AGENT_PLANNER" || true

    local plan_prompt
    plan_prompt=$(load_prompt "planner-plan") || { log "Cannot load planner-plan prompt"; return 1; }
    plan_prompt=$(render_prompt "$plan_prompt" \
        TASK_TITLE "$task_title" \
        TASK_BODY "$task_body")

    local plan_result
    plan_result=$(safe_claude "$AGENT" "$plan_prompt" \
    --allowedTools "Bash,Read,Glob,Grep") || {
        log "⚠️  Planning failed"
        reply_to_discussion "$task_num" "⚠️ Planning attempt failed. Will retry next cycle." "$AGENT_PLANNER" || true
        return 1
    }

    # Update the triage discussion — reply with plan + advance status
    local topic
    topic=$(extract_topic "$task_title")
    advance_status "$task_num" "PLANNING" "$topic" \
"## Implementation Plan

$plan_result

---
*Awaiting CTO approval before implementation begins.*" "$AGENT_PLANNER" || true

    mark_processed "$task_num" "$AGENT" "planned"
    log "✅ Plan added to #$task_num"
}

case "$MODE" in
    plan) run_plan ;;
    *)    echo "Usage: $0 {plan}"; exit 1 ;;
esac
