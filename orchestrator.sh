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

source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/robust.sh"

MODE="${1:---loop}"
CYCLE=0
CYCLE_SESSIONS=0
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

    # Track sessions per cycle for cost monitoring
    CYCLE_SESSIONS=$((CYCLE_SESSIONS + 1))
    local max_sessions="${MAX_SESSIONS_PER_CYCLE:-25}"
    if [ "$CYCLE_SESSIONS" -gt "$max_sessions" ]; then
        log "⚠️  Session budget exceeded ($CYCLE_SESSIONS/$max_sessions) — skipping $agent_name/$agent_mode"
        log_event "orchestrator" "BUDGET_SKIP" "$agent_name/$agent_mode (${CYCLE_SESSIONS}/${max_sessions} sessions)"
        return 0
    fi

    log "▶️  $agent_name/$agent_mode [session $CYCLE_SESSIONS/$max_sessions]"
    local start_time
    start_time=$(date +%s)

    if bash "$agent_script" "$agent_mode" 2>&1 | tee -a "$LOG_DIR/$agent_name.log"; then
        local elapsed=$(( $(date +%s) - start_time ))
        log "✅ $agent_name/$agent_mode (${elapsed}s)"
        log_event "orchestrator" "STEP_OK" "$agent_name/$agent_mode in ${elapsed}s [session $CYCLE_SESSIONS]"
    else
        local elapsed=$(( $(date +%s) - start_time ))
        log "⚠️  $agent_name/$agent_mode failed (${elapsed}s)"
        log_event "orchestrator" "STEP_FAIL" "$agent_name/$agent_mode after ${elapsed}s [session $CYCLE_SESSIONS]"
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
    CYCLE_SESSIONS=0
    log "═══ CYCLE $CYCLE ═══"
    log_event "orchestrator" "CYCLE_START" "Cycle $CYCLE (budget: ${MAX_SESSIONS_PER_CYCLE:-25} sessions)"

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

    # ── Queue checks (0 sessions) ──────────────
    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
    local staging_branch="${DEPLOY_BRANCH:-staging}"
    local focus_mode="${FOCUS_MODE:-false}"

    local has_open_prs
    has_open_prs=$(gh pr list --repo "$target_repo" --state open --base "$staging_branch" --json number --jq 'length' 2>/dev/null || echo "0")
    local has_new_issues
    has_new_issues=$(gh issue list --repo "$target_repo" --state open --json number --jq 'length' 2>/dev/null || echo "0")

    log "  PRs: $has_open_prs | Issues: $has_new_issues | Focus: $focus_mode"

    # ════════════════════════════════════════════
    # PHASE 1: DISCOVER (human input always, scans only in normal mode)
    # ════════════════════════════════════════════
    if [ "$has_new_issues" -gt 0 ]; then
        run_step "$SCRIPT_DIR/agents/product-manager.sh" "intake"
    fi

    # Check Q&A for human decisions (shell check before Claude session)
    local has_decisions
    has_decisions=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='query($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { discussions(first:5, states:OPEN) { nodes { title category { name } } } } }' --jq '[.data.repository.discussions.nodes[] | select(.category.name=="Q&A") | select(.title | contains("Decision"))] | length' 2>/dev/null || echo "0")
    if [ "$has_decisions" -gt 0 ]; then
        run_step "$SCRIPT_DIR/agents/product-manager.sh" "check-decisions"
    fi

    # CTO triage — only if there are open triage discussions to review
    local has_triage
    has_triage=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='query($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { discussions(first:5, states:OPEN) { nodes { title } } } }' --jq '[.data.repository.discussions.nodes[] | select(.title | contains("TRIAGE"))] | length' 2>/dev/null || echo "0")
    if [ "$has_triage" -gt 0 ]; then
        run_step "$SCRIPT_DIR/agents/cto.sh" "triage"
    fi

    # Scans — only in normal mode, and only when there's no work in progress
    # This prevents flooding triage when there are already items being worked on
    if [ "$focus_mode" != "true" ] && [ $((CYCLE % 5)) -eq 1 ]; then
        local open_triage
        open_triage=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='query($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { discussions(first:1, states:OPEN) { totalCount } } }' --jq '.data.repository.discussions.totalCount' 2>/dev/null || echo "0")
        if [ "$open_triage" -le 2 ]; then
            run_step "$SCRIPT_DIR/agents/cto.sh" "scan"
            run_step "$SCRIPT_DIR/agents/security.sh" "scan"
        else
            log "⏭️  Scans: $open_triage items already open — finish those first"
        fi
    fi

    # ════════════════════════════════════════════
    # PHASE 2: PLAN (skip if nothing to plan/approve)
    # ════════════════════════════════════════════
    if [ "$has_triage" -gt 0 ]; then
        run_step "$SCRIPT_DIR/agents/planner.sh" "plan"
    fi

    local has_planning
    has_planning=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='query($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { discussions(first:5, states:OPEN) { nodes { title } } } }' --jq '[.data.repository.discussions.nodes[] | select(.title | contains("PLANNING"))] | length' 2>/dev/null || echo "0")
    if [ "$has_planning" -gt 0 ]; then
        run_step "$SCRIPT_DIR/agents/cto.sh" "approve-plans"
    fi

    # ════════════════════════════════════════════
    # PHASE 3: BUILD (skip if nothing approved to build)
    # ════════════════════════════════════════════
    local has_approved
    has_approved=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='query($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { discussions(first:5, states:OPEN) { nodes { title } } } }' --jq '[.data.repository.discussions.nodes[] | select(.title | contains("APPROVED"))] | length' 2>/dev/null || echo "0")
    if [ "$has_approved" -gt 0 ]; then
        run_step "$SCRIPT_DIR/agents/senior-engineer.sh" "work"
    fi

    # ════════════════════════════════════════════
    # PHASE 4: VERIFY
    # ════════════════════════════════════════════
    if [ "$has_open_prs" -gt 0 ]; then
        run_step "$SCRIPT_DIR/agents/test-runner.sh" "verify"
        run_step "$SCRIPT_DIR/agents/reviewer.sh" "review"
        run_step "$SCRIPT_DIR/agents/security.sh" "review"
        run_step "$SCRIPT_DIR/agents/senior-engineer.sh" "respond-reviews"
    else
        log "⏭️  Verify: no open PRs — skipping"
    fi

    # ════════════════════════════════════════════
    # PHASE 5: SHIP (0 sessions)
    # ════════════════════════════════════════════
    if [ "$has_open_prs" -gt 0 ]; then
        run_step "$SCRIPT_DIR/agents/cto.sh" "review-prs"
    fi
    run_step "$SCRIPT_DIR/agents/devops.sh" "staging"
    run_step "$SCRIPT_DIR/agents/devops.sh" "deploy-verify"
    run_step "$SCRIPT_DIR/agents/sre.sh" "monitor"
    run_step "$SCRIPT_DIR/agents/quality-gate.sh" "check"

    # ════════════════════════════════════════════
    # PHASE 6: LEARN (both modes — compounds knowledge after merges)
    # ════════════════════════════════════════════
    local has_merged_work
    has_merged_work=$(gh pr list --repo "$target_repo" --state merged --base "$staging_branch" --json mergedAt --jq "[.[] | select(.mergedAt > \"$(date -u -v-1H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '2000-01-01')\")]| length" 2>/dev/null || echo "0")
    if [ "$has_merged_work" -gt 0 ]; then
        run_step "$SCRIPT_DIR/agents/compound.sh" "extract"
    fi

    if [ $((CYCLE % 5)) -eq 0 ]; then
        run_step "$SCRIPT_DIR/agents/self-improve.sh" "learn"
    fi

    # ════════════════════════════════════════════
    # PERIODIC AUDITS (normal mode only — creates new triage items)
    # ════════════════════════════════════════════
    if [ "$focus_mode" != "true" ]; then
        case $((CYCLE % 10)) in
            1) run_step "$SCRIPT_DIR/agents/security.sh" "audit" ;;
            3) run_step "$SCRIPT_DIR/agents/docs-writer.sh" "audit" ;;
            5) run_step "$SCRIPT_DIR/agents/dependency-auditor.sh" "audit" ;;
            7) run_step "$SCRIPT_DIR/agents/accessibility-auditor.sh" "audit" ;;
            9) run_step "$SCRIPT_DIR/agents/sre.sh" "env-audit" ;;
            0) run_step "$SCRIPT_DIR/agents/qa-writer.sh" "generate" ;;
        esac

        if [ $((CYCLE % 5)) -eq 0 ]; then
            run_step "$SCRIPT_DIR/agents/quality-gate.sh" "report"
        fi

        if [ $((CYCLE % 20)) -eq 0 ]; then
            run_step "$SCRIPT_DIR/agents/release-manager.sh" "changelog"
        fi
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
