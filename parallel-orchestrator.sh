#!/bin/bash
# ============================================================
# 🚀 Parallel Orchestrator
#
# Unlike the sequential orchestrator.sh, this one runs agents
# CONCURRENTLY in separate tmux panes. Each agent runs its own
# independent loop.
#
# This is closer to the "hundreds of agents" setup from the
# video — each agent is autonomous and polls for its own work.
#
# With 1 Claude Code Max sub: run agents sequentially (orchestrator.sh)
# With 2-3 subs: run 2-3 agents in parallel (this script)
#
# Usage:
#   ./parallel-orchestrator.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config-loader.sh"

# Parse --project flag from args
eval "$(parse_project_flag "$@")"

source "$SCRIPT_DIR/lib/discussions.sh"

SESSION_NAME="agent-factory"

log() { echo "[$(date '+%H:%M:%S')] [PARALLEL] $*" | tee -a "$LOG_DIR/orchestrator.log"; }

# ────────────────────────────────────────────
# Agent loop — each agent runs independently
# ────────────────────────────────────────────

# CTO loop: scan every 5 cycles, triage + review-prs every cycle
run_cto_loop() {
    local cycle=0
    while true; do
        cycle=$((cycle + 1))
        log "[CTO] Cycle $cycle"

        if [ $((cycle % 5)) -eq 1 ]; then
            bash "$SCRIPT_DIR/agents/cto.sh" scan 2>&1 || true
        fi

        bash "$SCRIPT_DIR/agents/cto.sh" triage 2>&1 || true
        bash "$SCRIPT_DIR/agents/cto.sh" review-prs 2>&1 || true

        if [ $((cycle % 24)) -eq 0 ]; then
            bash "$SCRIPT_DIR/agents/cto.sh" standup 2>&1 || true
        fi

        log "[CTO] Sleeping ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
    done
}

# Engineer loop: pick up tasks, respond to reviews
run_engineer_loop() {
    while true; do
        log "[ENG] Looking for work..."

        bash "$SCRIPT_DIR/agents/senior-engineer.sh" work 2>&1 || true

        sleep 30  # Small gap between work and review check

        bash "$SCRIPT_DIR/agents/senior-engineer.sh" respond-reviews 2>&1 || true

        log "[ENG] Sleeping ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
    done
}

# Reviewer loop: review PRs
run_reviewer_loop() {
    while true; do
        log "[REV] Checking for PRs to review..."

        bash "$SCRIPT_DIR/agents/reviewer.sh" review 2>&1 || true

        log "[REV] Sleeping ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
    done
}

# ────────────────────────────────────────────
# Launch all loops in tmux panes
# ────────────────────────────────────────────
main() {
    log "🚀 Starting Parallel Orchestrator"
    log "   Each agent runs its own loop in a separate pane."
    log ""

    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log "No tmux session found. Use ./factory.sh start instead,"
        log "or run agents manually:"
        log ""
        log "  Terminal 1: ./parallel-orchestrator.sh cto"
        log "  Terminal 2: ./parallel-orchestrator.sh engineer"
        log "  Terminal 3: ./parallel-orchestrator.sh reviewer"
        exit 1
    fi

    # If called with a specific agent, run just that loop
    case "${1:-all}" in
        cto)      run_cto_loop ;;
        engineer) run_engineer_loop ;;
        reviewer) run_reviewer_loop ;;
        all)
            # Send each loop to its tmux pane
            tmux send-keys -t "$SESSION_NAME:factory.1" \
                "cd '$SCRIPT_DIR' && ./parallel-orchestrator.sh cto 2>&1 | tee '$LOG_DIR/cto.log'" Enter

            tmux send-keys -t "$SESSION_NAME:factory.2" \
                "cd '$SCRIPT_DIR' && ./parallel-orchestrator.sh engineer 2>&1 | tee '$LOG_DIR/senior-engineer.log'" Enter

            tmux send-keys -t "$SESSION_NAME:factory.3" \
                "cd '$SCRIPT_DIR' && ./parallel-orchestrator.sh reviewer 2>&1 | tee '$LOG_DIR/reviewer.log'" Enter

            log "✅ All agent loops started in their tmux panes."
            ;;
    esac
}

main "$@"
