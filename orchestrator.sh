#!/bin/bash
# ============================================================
# 🤖 Orchestrator — Robust, single-subscription agent loop
#
# Runs agents sequentially with:
# - Locking (only 1 claude session at a time)
# - State tracking (never processes the same discussion twice)
# - Retries with exponential backoff on failures
# - Timeout protection (kills hung claude sessions)
# - Health checks every N cycles
# - Log rotation
# - Graceful shutdown on Ctrl+C
#
# Usage:
#   ./orchestrator.sh              # Run forever
#   ./orchestrator.sh --once       # One cycle, then exit
#   ./orchestrator.sh --dry-run    # Show what would run
# ============================================================
# NOTE: no `set -e` — the orchestrator must NEVER exit on a failed step.
# Agent failures are expected and handled. Only `set -u` (undefined vars)
# and `set -o pipefail` (pipe errors) are used.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config-loader.sh"

# Parse --project flag from args before processing other flags
eval "$(parse_project_flag "$@")"

source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/robust.sh"

MODE="${1:---loop}"
CYCLE=0
RUNNING=true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ORCH] $*" | tee -a "$LOG_DIR/orchestrator.log"; }

# Graceful shutdown
# Release all pool slots on shutdown (global lock dir)
_release_all_slots() {
    local i=0
    local pool_size="${MAX_PARALLEL_SESSIONS:-1}"
    while [ "$i" -lt "$pool_size" ]; do
        release_pool_slot "claude" "$i" 2>/dev/null || true
        i=$((i + 1))
    done
}
trap 'RUNNING=false; log "🛑 Shutdown requested, finishing current step..."; _release_all_slots' INT TERM

# ────────────────────────────────────────────
# Resolve agent script — project override takes precedence
# ────────────────────────────────────────────
resolve_agent() {
    local agent_script="$1"
    local agent_filename
    agent_filename=$(basename "$agent_script")

    if [ -n "${PROJECT_DIR:-}" ] && [ -f "$PROJECT_DIR/agents/$agent_filename" ]; then
        echo "$PROJECT_DIR/agents/$agent_filename"
    else
        echo "$agent_script"
    fi
}

# ────────────────────────────────────────────
# Run a single agent step with full robustness
# ────────────────────────────────────────────
run_step() {
    local agent_script
    agent_script=$(resolve_agent "$1")
    local agent_mode="$2"
    local agent_name
    agent_name=$(basename "$agent_script" .sh)

    # Check if we should stop
    if [ "$RUNNING" != "true" ]; then
        log "⏹️  Skipping $agent_name/$agent_mode (shutting down)"
        return 0
    fi

    if [ "$MODE" = "--dry-run" ]; then
        log "[DRY] Would run: $agent_name $agent_mode"
        return 0
    fi

    log "▶️  $agent_name/$agent_mode"
    local start_time
    start_time=$(date +%s)

    if bash "$agent_script" "$agent_mode" 2>&1 | tee -a "$LOG_DIR/$agent_name.log"; then
        local elapsed=$(( $(date +%s) - start_time ))
        log "✅ $agent_name/$agent_mode (${elapsed}s)"
        log_event "orchestrator" "STEP_OK" "$agent_name/$agent_mode in ${elapsed}s"
    else
        local elapsed=$(( $(date +%s) - start_time ))
        log "⚠️  $agent_name/$agent_mode failed (${elapsed}s)"
        log_event "orchestrator" "STEP_FAIL" "$agent_name/$agent_mode after ${elapsed}s"
    fi

    # Small buffer between steps to be kind to rate limits
    if [ "$RUNNING" = "true" ]; then
        sleep 5
    fi
}

# ────────────────────────────────────────────
# One full cycle
# ────────────────────────────────────────────
run_cycle() {
    CYCLE=$((CYCLE + 1))
    log "═══ CYCLE $CYCLE ═══"
    log_event "orchestrator" "CYCLE_START" "Cycle $CYCLE"

    # Health check every 10 cycles
    if [ $((CYCLE % 10)) -eq 1 ]; then
        if ! health_check; then
            log "⚠️  Health check failed — pausing 60s"
            sleep 60
            if ! health_check; then
                log "❌ Health check still failing — skipping this cycle"
                log_event "orchestrator" "HEALTH_FAIL" "Two consecutive health check failures"
                return 0  # Don't crash — just skip this cycle
            fi
        fi
        rotate_logs
    fi

    # Phase 1: CTO scans (every 5 cycles — not every time)
    if [ $((CYCLE % 5)) -eq 1 ]; then
        run_step "$SCRIPT_DIR/agents/cto.sh" "scan"
    fi

    # Phase 2: Engineer picks up a task
    run_step "$SCRIPT_DIR/agents/senior-engineer.sh" "work"

    # Phase 3: Reviewer reviews
    run_step "$SCRIPT_DIR/agents/reviewer.sh" "review"

    # Phase 4: Engineer responds to review feedback
    run_step "$SCRIPT_DIR/agents/senior-engineer.sh" "respond-reviews"

    # Phase 5: CTO triages
    run_step "$SCRIPT_DIR/agents/cto.sh" "triage"

    # Phase 6: CTO merges approved PRs
    run_step "$SCRIPT_DIR/agents/cto.sh" "review-prs"

    # Phase 7: Standup every ~24 cycles
    if [ $((CYCLE % 24)) -eq 0 ]; then
        run_step "$SCRIPT_DIR/agents/cto.sh" "standup"
    fi

    log_event "orchestrator" "CYCLE_DONE" "Cycle $CYCLE complete"
    log "═══ CYCLE $CYCLE done ═══"
}

# ────────────────────────────────────────────
# Main
# ────────────────────────────────────────────
main() {
    log "🏭 Agent Factory — Orchestrator"
    log "   Profile:  ${PROJECT_NAME:-<base>}"
    log "   Project:  $TARGET_PROJECT"
    log "   Repo:     $GITHUB_REPO_FULL"
    log "   Interval: ${POLL_INTERVAL}s"
    log "   Mode:     $MODE"

    # Initial health check
    if ! health_check; then
        log "❌ Pre-flight health check failed. Fix issues above."
        exit 1
    fi
    log "✅ Health check passed"

    case "$MODE" in
        --once)
            run_cycle
            log "Done."
            ;;
        --dry-run)
            run_cycle
            log "Dry run done."
            ;;
        --loop|*)
            log "🔁 Looping (Ctrl+C to stop gracefully)"

            while [ "$RUNNING" = "true" ]; do
                run_cycle

                if [ "$RUNNING" = "true" ]; then
                    log "💤 Next cycle in ${POLL_INTERVAL}s..."
                    # Sleep in small increments so Ctrl+C is responsive
                    local waited=0
                    while [ "$waited" -lt "$POLL_INTERVAL" ] && [ "$RUNNING" = "true" ]; do
                        sleep 5
                        waited=$((waited + 5))
                    done
                fi
            done

            log "🛑 Orchestrator stopped cleanly."
            ;;
    esac
}

main "$@"
