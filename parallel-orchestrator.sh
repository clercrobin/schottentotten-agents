#!/bin/bash
# ============================================================
# 🚀 Parallel Orchestrator — Compound Engineering
#
# Runs agents CONCURRENTLY in separate tmux panes, following
# the Plan → Work → Review → Compound cycle.
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

# Parse --project and --env flags from args
eval "$(parse_project_flag "$@")"
eval "$(parse_env_flag "$@")"

source "$SCRIPT_DIR/lib/discussions.sh"

SESSION_NAME="agent-factory"

log() { echo "[$(date '+%H:%M:%S')] [PARALLEL] $*" | tee -a "$LOG_DIR/orchestrator.log"; }

# ────────────────────────────────────────────
# Agent loops — each agent runs independently
# ────────────────────────────────────────────

# CTO loop: scan, triage, approve plans, merge PRs
run_cto_loop() {
    local cycle=0
    while true; do
        cycle=$((cycle + 1))
        log "[CTO] Cycle $cycle"

        if [ $((cycle % 5)) -eq 1 ]; then
            bash "$SCRIPT_DIR/agents/cto.sh" scan 2>&1 || true
        fi

        bash "$SCRIPT_DIR/agents/cto.sh" triage 2>&1 || true
        bash "$SCRIPT_DIR/agents/cto.sh" approve-plans 2>&1 || true
        bash "$SCRIPT_DIR/agents/cto.sh" review-prs 2>&1 || true

        if [ $((cycle % 24)) -eq 0 ]; then
            bash "$SCRIPT_DIR/agents/cto.sh" standup 2>&1 || true
        fi

        log "[CTO] Sleeping ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
    done
}

# Researcher + Planner loop: research then plan
run_planner_loop() {
    while true; do
        log "[RES] Researching triaged issues..."
        bash "$SCRIPT_DIR/agents/researcher.sh" research 2>&1 || true
        sleep 10
        log "[PLAN] Creating implementation plans..."
        bash "$SCRIPT_DIR/agents/planner.sh" plan 2>&1 || true
        log "[PLAN] Sleeping ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
    done
}

# Engineer loop: implement approved plans, respond to reviews
run_engineer_loop() {
    while true; do
        log "[ENG] Looking for approved plans..."
        bash "$SCRIPT_DIR/agents/senior-engineer.sh" work 2>&1 || true
        sleep 30
        bash "$SCRIPT_DIR/agents/senior-engineer.sh" respond-reviews 2>&1 || true
        log "[ENG] Sleeping ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
    done
}

# Reviewer loop: multi-perspective code review
run_reviewer_loop() {
    while true; do
        log "[REV] Checking for PRs to review..."
        bash "$SCRIPT_DIR/agents/reviewer.sh" review 2>&1 || true
        log "[REV] Sleeping ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
    done
}

# Compound loop: extract learnings from merged work
run_compound_loop() {
    while true; do
        log "[COMP] Looking for merged work to compound..."
        bash "$SCRIPT_DIR/agents/compound.sh" extract 2>&1 || true
        # Compound runs less frequently — knowledge extraction doesn't need to be instant
        log "[COMP] Sleeping $(( POLL_INTERVAL * 3 ))s..."
        sleep $(( POLL_INTERVAL * 3 ))
    done
}

# ────────────────────────────────────────────
# Launch all loops in tmux panes
# ────────────────────────────────────────────
main() {
    log "🚀 Starting Parallel Orchestrator (Compound Engineering)"
    log "   Cycle: Plan → Work → Review → Compound"
    log ""

    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log "No tmux session found. Use ./factory.sh start instead,"
        log "or run agents manually:"
        log ""
        log "  Terminal 1: ./parallel-orchestrator.sh cto"
        log "  Terminal 2: ./parallel-orchestrator.sh planner"
        log "  Terminal 3: ./parallel-orchestrator.sh engineer"
        log "  Terminal 4: ./parallel-orchestrator.sh reviewer"
        log "  Terminal 5: ./parallel-orchestrator.sh compound"
        exit 1
    fi

    # If called with a specific agent, run just that loop
    case "${1:-all}" in
        cto)      run_cto_loop ;;
        planner)  run_planner_loop ;;
        engineer) run_engineer_loop ;;
        reviewer) run_reviewer_loop ;;
        compound) run_compound_loop ;;
        all)
            tmux send-keys -t "$SESSION_NAME:factory.1" \
                "cd '$SCRIPT_DIR' && ./parallel-orchestrator.sh cto 2>&1 | tee '$LOG_DIR/cto.log'" Enter

            tmux send-keys -t "$SESSION_NAME:factory.2" \
                "cd '$SCRIPT_DIR' && ./parallel-orchestrator.sh planner 2>&1 | tee '$LOG_DIR/planner.log'" Enter

            tmux send-keys -t "$SESSION_NAME:factory.3" \
                "cd '$SCRIPT_DIR' && ./parallel-orchestrator.sh engineer 2>&1 | tee '$LOG_DIR/senior-engineer.log'" Enter

            tmux send-keys -t "$SESSION_NAME:factory.4" \
                "cd '$SCRIPT_DIR' && ./parallel-orchestrator.sh reviewer 2>&1 | tee '$LOG_DIR/reviewer.log'" Enter

            tmux send-keys -t "$SESSION_NAME:factory.5" \
                "cd '$SCRIPT_DIR' && ./parallel-orchestrator.sh compound 2>&1 | tee '$LOG_DIR/compound.log'" Enter

            log "✅ All agent loops started in their tmux panes."
            ;;
    esac
}

main "$@"
