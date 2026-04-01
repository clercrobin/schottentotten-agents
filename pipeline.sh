#!/bin/bash
# ============================================================
# 🚀 Pipeline — Event-driven feature processing
#
# Runs a feature through the entire lifecycle in one continuous
# flow. No polling, no sleep, no wasted cycles.
#
# Usage:
#   ./pipeline.sh --project schottentotten --env staging <feature_id>
#   ./pipeline.sh --project schottentotten --env staging --intake
#   ./pipeline.sh --project schottentotten --env staging --loop
#
# Modes:
#   <feature_id>   Process one feature through its remaining lifecycle
#   --intake       Check for new Ideas, create state files, then process
#   --loop         Continuous: intake + process highest priority feature
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config-loader.sh"

# Parse flags
eval "$(parse_project_flag "$@")"
eval "$(parse_env_flag "$@")"

source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/robust.sh"
source "$SCRIPT_DIR/lib/feature-state.sh"
source "$SCRIPT_DIR/lib/discussions.sh"

# Get the action (last positional arg after flags are stripped)
ACTION="${1:-}"

log() { echo "[$(date '+%H:%M:%S')] [PIPE] $*"; }

# ────────────────────────────────────────────
# Run a single agent and check result
# Returns 0 on success, 1 on failure
# ────────────────────────────────────────────
run_agent() {
    local agent="$1"
    local arg="$2"
    local start_time elapsed

    log "  ▶ $agent $arg"
    start_time=$(date +%s)

    if PROJECT_NAME="$PROJECT_NAME" ENV_NAME="$ENV_NAME" \
       bash "$SCRIPT_DIR/agents/$agent" "$arg" 2>&1 | tee -a "${LOG_DIR:-logs}/pipeline.log"; then
        elapsed=$(( $(date +%s) - start_time ))
        log "  ✅ $agent (${elapsed}s)"
        return 0
    else
        elapsed=$(( $(date +%s) - start_time ))
        log "  ❌ $agent failed (${elapsed}s)"
        return 1
    fi
}

# ────────────────────────────────────────────
# Process a feature through its remaining lifecycle
# Reads current status, runs the next agent, repeats until done
# ────────────────────────────────────────────
process_feature() {
    local fid="$1"
    local start_time
    start_time=$(date +%s)

    log "═══ Processing feature #$fid ═══"

    while true; do
        local status
        status=$(feature_field "$fid" "status")
        local topic
        topic=$(feature_field "$fid" "topic")

        log "  Status: $status | $topic"

        case "$status" in
            triage)
                run_agent "planner.sh" "$fid" || break
                ;;
            planning)
                run_agent "cto.sh" "approve $fid" || break
                # Check if CTO rejected — status goes back to triage
                local new_status
                new_status=$(feature_field "$fid" "status")
                if [ "$new_status" = "triage" ]; then
                    log "  🔄 CTO rejected — planner will iterate"
                    run_agent "planner.sh" "$fid" || break
                    continue
                fi
                ;;
            approved|building)
                run_agent "senior-engineer.sh" "$fid" || break
                ;;
            review)
                local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
                run_agent "reviewer.sh" "$fid" || break
                # If reviewed, try to merge PR to staging
                local new_status
                new_status=$(feature_field "$fid" "status")
                if [ "$new_status" = "reviewed" ]; then
                    local pr_num
                    pr_num=$(feature_field "$fid" "pr")
                    if [ -n "$pr_num" ] && [ "$pr_num" != "None" ]; then
                        log "  🔀 Merging PR #$pr_num to staging"
                        gh pr merge "$pr_num" --repo "$target_repo" --squash --delete-branch 2>/dev/null && {
                            feature_set_status "$fid" "done"
                            local discussion
                            discussion=$(feature_field "$fid" "discussion")
                            [ -n "$discussion" ] && [ "$discussion" != "null" ] && \
                                reply_to_discussion "$discussion" "✅ **Merged to staging.** PR #$pr_num shipped." "🚀 Pipeline" 2>/dev/null || true
                        } || log "  ⚠️ Merge failed"
                    fi
                fi
                ;;
            reviewed|done)
                log "  ✅ Feature #$fid complete"
                break
                ;;
            *)
                log "  ❓ Unknown status: $status"
                break
                ;;
        esac

        # Safety: check if status actually changed (prevent infinite loop)
        local new_status
        new_status=$(feature_field "$fid" "status")
        if [ "$new_status" = "$status" ] && [ "$new_status" != "triage" ]; then
            log "  ⚠️ Status didn't change ($status) — stopping to prevent loop"
            break
        fi
    done

    local elapsed=$(( $(date +%s) - start_time ))
    log "═══ Feature #$fid done in ${elapsed}s ═══"
}

# ────────────────────────────────────────────
# Intake: check for new Ideas, create state files
# ────────────────────────────────────────────
do_intake() {
    run_agent "product-manager.sh" "intake"
    run_agent "product-manager.sh" "check-decisions"
}

# ────────────────────────────────────────────
# Main
# ────────────────────────────────────────────
case "$ACTION" in
    --intake)
        do_intake
        ;;
    --loop)
        log "🔁 Pipeline loop — Ctrl+C to stop"
        trap 'log "🛑 Stopping..."; pkill -P $$ 2>/dev/null; exit 0' INT TERM

        while true; do
            # Intake new work
            do_intake

            # Find highest priority feature to process
            local fid
            fid=$(feature_find_by_status "triage" "planning" "approved" "building" "review")

            if [ -n "$fid" ]; then
                process_feature "$fid"
            else
                log "💤 No work — checking staging health"
                run_agent "quality-gate.sh" "check"
                run_agent "sre.sh" "monitor"

                # Normal mode: scan for new issues periodically
                if [ "${FOCUS_MODE:-false}" != "true" ]; then
                    run_agent "cto.sh" "scan"
                fi

                log "💤 Sleeping 60s..."
                sleep 60
            fi
        done
        ;;
    --help|-h|"")
        echo "🚀 Pipeline — Event-driven feature processing"
        echo ""
        echo "Usage:"
        echo "  ./pipeline.sh --project <name> --env <env> <feature_id>"
        echo "  ./pipeline.sh --project <name> --env <env> --intake"
        echo "  ./pipeline.sh --project <name> --env <env> --loop"
        echo ""
        echo "Current features:"
        feature_list
        ;;
    *)
        # Assume it's a feature ID
        process_feature "$ACTION"
        ;;
esac
