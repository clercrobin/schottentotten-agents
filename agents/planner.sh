#!/bin/bash
# ============================================================
# 📋 Planner Agent — Stateful version
#
# Receives feature ID. Reads state. Writes plan to disk.
# On re-plan (CTO rejection), reads feedback and amends.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_AGENT_MODE="${1:-}"
set --
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"
source "$SCRIPT_DIR/../lib/feature-state.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"

FEATURE_ID="${_AGENT_MODE:-}"
AGENT="planner"
log() { echo "[$(date '+%H:%M:%S')] [PLAN] $*"; }

[ -z "$FEATURE_ID" ] && { log "No feature ID"; exit 1; }

topic=$(feature_field "$FEATURE_ID" "topic")
plan_file=$(feature_field "$FEATURE_ID" "plan")
discussion=$(feature_field "$FEATURE_ID" "discussion")

log "📋 Planning #$FEATURE_ID: $topic"

# Check for prior feedback
feedback=""
if [ -f "$plan_file" ]; then
    feedback=$(python3 -c "
import json
with open('$_FEATURE_DIR/${FEATURE_ID}.json') as f:
    d = json.load(f)
for fb in d.get('feedback', []):
    print(f\"- [{fb['verdict']}] {fb['note']}\")
" 2>/dev/null)
fi

if [ -n "$feedback" ]; then
    log "  Iterating ($(echo "$feedback" | wc -l | tr -d ' ') feedback items)"
    prompt_text="Amend this plan based on CTO feedback.

## Feature: $topic

## Current Plan (first 200 lines):
$(head -200 "$plan_file")

## Feedback:
$feedback

Output the COMPLETE updated plan."
else
    log "  New plan"
    prompt_text=$(load_prompt "planner-plan") || exit 1
    prompt_text=$(render_prompt "$prompt_text" TASK_TITLE "$topic" TASK_BODY "$topic")
fi

result=$(safe_claude "$AGENT" "$prompt_text" --allowedTools "Bash,Read,Glob,Grep") || exit 1

mkdir -p "$(dirname "$plan_file")"
echo "$result" > "$plan_file"
log "  Written: $plan_file ($(wc -c < "$plan_file" | tr -d ' ')b)"

feature_set_status "$FEATURE_ID" "planning"

[ -n "$discussion" ] && [ "$discussion" != "null" ] && \
    reply_to_discussion "$discussion" "📋 **Plan ready.** Awaiting CTO approval." "$AGENT" 2>/dev/null || true

log "✅ #$FEATURE_ID planned"
