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
    local start_time max_iterations iteration prev_status
    start_time=$(date +%s)
    max_iterations=10  # Safety: max agent invocations per feature
    iteration=0

    log "═══ Processing feature #$fid ═══"

    while [ "$iteration" -lt "$max_iterations" ]; do
        iteration=$((iteration + 1))
        local status topic
        status=$(feature_field "$fid" "status")
        topic=$(feature_field "$fid" "topic")

        log "  [$iteration/$max_iterations] $status → $(
            case "$status" in
                triage)           echo "planner" ;;
                planning)         echo "cto approve" ;;
                approved|building) echo "engineer" ;;
                review)           echo "reviewer" ;;
                reviewed)         echo "merge to staging" ;;
                done)             echo "complete" ;;
                *)                echo "?" ;;
            esac
        )"

        # ── State machine: status → agent ──
        case "$status" in
            triage)
                run_agent "planner.sh" "$fid"
                ;;
            planning)
                run_agent "cto.sh" "approve $fid"
                ;;
            approved|building)
                run_agent "senior-engineer.sh" "$fid"
                ;;
            review)
                run_agent "reviewer.sh" "$fid"
                ;;
            reviewed)
                # Merge PR to staging
                local pr_num target_repo
                pr_num=$(feature_field "$fid" "pr")
                target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
                if [ -n "$pr_num" ] && [ "$pr_num" != "None" ]; then
                    log "  🔀 Merging PR #$pr_num to staging"
                    if gh pr merge "$pr_num" --repo "$target_repo" --squash --delete-branch 2>/dev/null; then
                        feature_set_status "$fid" "done"
                        local discussion
                        discussion=$(feature_field "$fid" "discussion")
                        [ -n "$discussion" ] && [ "$discussion" != "null" ] && \
                            reply_to_discussion "$discussion" "✅ **Merged to staging.** PR #$pr_num shipped." "🚀 Pipeline" 2>/dev/null || true
                    else
                        log "  ⚠️ Merge failed — will retry"
                    fi
                else
                    log "  ⚠️ No PR number — cannot merge"
                    break
                fi
                ;;
            done)
                break
                ;;
            *)
                log "  ❓ Unknown status: $status — stopping"
                break
                ;;
        esac

        # ── Check what happened ──
        local new_status
        new_status=$(feature_field "$fid" "status")

        if [ "$new_status" = "done" ]; then
            break
        fi

        # Agent failed to change status — don't loop forever
        if [ "$new_status" = "$status" ]; then
            log "  ⚠️ Status unchanged ($status) — agent may have failed, stopping"
            break
        fi

        # Log the transition
        log "  → $status → $new_status"
    done

    local elapsed=$(( $(date +%s) - start_time ))
    local final_status
    final_status=$(feature_field "$fid" "status")
    log "═══ #$fid: $final_status in ${elapsed}s ($iteration steps) ═══"
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
