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

# Parse --project and --env flags from args
eval "$(parse_project_flag "$@")"
eval "$(parse_env_flag "$@")"

source "$SCRIPT_DIR/lib/feature-state.sh"

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
trap 'RUNNING=false; log "🛑 Shutdown — killing child processes..."; pkill -P $$ 2>/dev/null; pkill -f "claude -p" 2>/dev/null; _release_all_slots' INT TERM

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

    if PROJECT_NAME="$PROJECT_NAME" ENV_NAME="$ENV_NAME" bash "$agent_script" "$agent_mode" 2>&1 | tee -a "$LOG_DIR/$agent_name.log"; then
        local elapsed=$(( $(date +%s) - start_time ))
        log "✅ $agent_name/$agent_mode (${elapsed}s)"
        log_event "orchestrator" "STEP_OK" "$agent_name/$agent_mode in ${elapsed}s"
    else
        local elapsed=$(( $(date +%s) - start_time ))
        log "⚠️  $agent_name/$agent_mode failed (${elapsed}s)"
        log_event "orchestrator" "STEP_FAIL" "$agent_name/$agent_mode after ${elapsed}s"
    fi

    # Brief pause between steps (1s, not 5s — rate limits are per-minute, not per-second)
    if [ "$RUNNING" = "true" ]; then
        sleep 1
    fi
}

# ────────────────────────────────────────────
# One full cycle — Compound Engineering loop:
#   Plan → Work → Review → Compound
#
# "Plan and review comprise 80% of engineering time;
#  work and compound account for 20%."
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
            health_check || { log "❌ Still failing — skip"; return 0; }
        fi
        rotate_logs
    fi

    # ── Read state from files (0 API calls, 0 sessions) ────
    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
    local staging_branch="${DEPLOY_BRANCH:-staging}"
    local focus_mode="${FOCUS_MODE:-false}"

    # Count features by status — reads local JSON files, instant
    local n_triage n_planning n_approved n_building n_review n_done
    n_triage=$(feature_count "triage")
    n_planning=$(feature_count "planning")
    n_approved=$(feature_count "approved")
    n_building=$(feature_count "building")
    n_review=$(feature_count "review")

    local has_open_prs
    has_open_prs=$(gh pr list --repo "$target_repo" --state open --base "$staging_branch" --json number --jq 'length' 2>/dev/null || echo "0")

    local staging_ci
    staging_ci=$(gh run list --repo "$target_repo" --branch "$staging_branch" --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "unknown")

    log "  State: triage=$n_triage plan=$n_planning approved=$n_approved build=$n_building review=$n_review prs=$has_open_prs ci=$staging_ci"

    # ── 1. Human input (always) ──
    run_step "$SCRIPT_DIR/agents/product-manager.sh" "intake"
    run_step "$SCRIPT_DIR/agents/product-manager.sh" "check-decisions"

    # ── Dispatch: pick the most urgent action ─────────────

    # Staging CI failed → create fix task
    if [ "$staging_ci" = "failure" ]; then
        log "  → CI failed — quality gate"
        run_step "$SCRIPT_DIR/agents/quality-gate.sh" "check"

    # PRs need review
    elif [ "$has_open_prs" -gt 0 ]; then
        local fid
        fid=$(feature_find_by_status "review" "building")
        log "  → $has_open_prs PRs open — review #$fid"
        run_step "$SCRIPT_DIR/agents/reviewer.sh" "$fid"
        run_step "$SCRIPT_DIR/agents/security.sh" "review-feature $fid"
        run_step "$SCRIPT_DIR/agents/cto.sh" "review-prs"

    # Approved/building items → engineer builds
    elif [ "$n_approved" -gt 0 ] || [ "$n_building" -gt 0 ]; then
        local fid
        fid=$(feature_find_by_status "approved" "building")
        log "  → Engineer builds #$fid"
        run_step "$SCRIPT_DIR/agents/senior-engineer.sh" "$fid"

    # Planning items → CTO approves
    elif [ "$n_planning" -gt 0 ]; then
        local fid
        fid=$(feature_find_by_status "planning")
        log "  → CTO approves plan #$fid"
        run_step "$SCRIPT_DIR/agents/cto.sh" "approve $fid"

    # Triage items → planner plans
    elif [ "$n_triage" -gt 0 ]; then
        local fid
        fid=$(feature_find_by_status "triage")
        log "  → Planner plans #$fid"
        run_step "$SCRIPT_DIR/agents/planner.sh" "$fid"

    # All green → quality gate
    elif [ "$staging_ci" = "success" ] && [ "$has_open_prs" -eq 0 ]; then
        log "  → Staging green — quality gate"
        run_step "$SCRIPT_DIR/agents/devops.sh" "deploy-verify"
        run_step "$SCRIPT_DIR/agents/sre.sh" "monitor"
        run_step "$SCRIPT_DIR/agents/quality-gate.sh" "check"

    # Nothing → scan (normal mode only)
    elif [ "$focus_mode" != "true" ] && [ $((CYCLE % 5)) -eq 1 ]; then
        log "  → Scanning for new work"
        run_step "$SCRIPT_DIR/agents/cto.sh" "scan"

    else
        log "  → Idle"
    fi

    # ── Learn (after dispatch) ──
    if [ $((CYCLE % 5)) -eq 0 ]; then
        run_step "$SCRIPT_DIR/agents/self-improve.sh" "learn"
    fi

    # ── Periodic audits (normal mode only) ──
    if [ "$focus_mode" != "true" ]; then
        case $((CYCLE % 10)) in
            3) run_step "$SCRIPT_DIR/agents/docs-writer.sh" "audit" ;;
            5) run_step "$SCRIPT_DIR/agents/dependency-auditor.sh" "audit" ;;
            7) run_step "$SCRIPT_DIR/agents/accessibility-auditor.sh" "audit" ;;
            9) run_step "$SCRIPT_DIR/agents/sre.sh" "env-audit" ;;
        esac
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
    log "   Env:      ${ENV_NAME:-prod}"
    log "   Project:  $TARGET_PROJECT"
    log "   Branch:   ${DEPLOY_BRANCH:-main}"
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
