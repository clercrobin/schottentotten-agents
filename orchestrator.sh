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

    if PROJECT_NAME="$PROJECT_NAME" ENV_NAME="$ENV_NAME" bash "$agent_script" "$agent_mode" 2>&1 | tee -a "$LOG_DIR/$agent_name.log"; then
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

    # ── Read state (all shell, 0 sessions) ────────────────
    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
    local staging_branch="${DEPLOY_BRANCH:-staging}"
    local focus_mode="${FOCUS_MODE:-false}"

    # One API call to get all open discussion titles
    local all_titles
    all_titles=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        discussions(first: 20, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes { title category { name } }
        }
      }
    }' --jq '.data.repository.discussions.nodes[] | "\(.category.name)\t\(.title)"' 2>/dev/null || echo "")

    local has_triage has_planning has_approved has_review has_decisions
    has_triage=$(echo "$all_titles" | grep -cE "\[TRIAGE\]|\[FEATURE\]" 2>/dev/null || echo "0")
    has_planning=$(echo "$all_titles" | grep -c "\[PLANNING\]" 2>/dev/null || echo "0")
    has_approved=$(echo "$all_titles" | grep -cE "\[APPROVED\]|\[BUILDING\]" 2>/dev/null || echo "0")
    has_review=$(echo "$all_titles" | grep -c "\[REVIEW\]" 2>/dev/null || echo "0")
    has_decisions=$(echo "$all_titles" | grep -c "Decision needed" 2>/dev/null || echo "0")
    # Sanitize to integers
    has_triage=${has_triage//[^0-9]/}; has_triage=${has_triage:-0}
    has_planning=${has_planning//[^0-9]/}; has_planning=${has_planning:-0}
    has_approved=${has_approved//[^0-9]/}; has_approved=${has_approved:-0}
    has_review=${has_review//[^0-9]/}; has_review=${has_review:-0}
    has_decisions=${has_decisions//[^0-9]/}; has_decisions=${has_decisions:-0}

    local has_open_prs
    has_open_prs=$(gh pr list --repo "$target_repo" --state open --base "$staging_branch" --json number --jq 'length' 2>/dev/null || echo "0")
    local has_new_issues
    has_new_issues=$(gh issue list --repo "$target_repo" --state open --json number --jq 'length' 2>/dev/null || echo "0")
    # Also check for new Ideas in the agents repo (human feature requests)
    local has_new_ideas
    has_new_ideas=$(echo "$all_titles" | grep -c "Ideas" || echo "0")
    has_new_issues=$((has_new_issues + has_new_ideas))

    # Check staging CI status (shell)
    local staging_ci
    staging_ci=$(gh run list --repo "$target_repo" --branch "$staging_branch" --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "unknown")

    log "  State: triage=$has_triage planning=$has_planning approved=$has_approved review=$has_review prs=$has_open_prs ci=$staging_ci"

    # ── Dispatch: pick the most urgent action ─────────────
    #
    # Priority order (highest first):
    #   1. Human input (always)
    #   2. Staging CI failed → create fix task
    #   3. PRs need review → reviewer + security
    #   4. Approved items → engineer builds
    #   5. Planning items → CTO approves
    #   6. Triage items → planner plans
    #   7. Staging CI green, no work → quality gate Q&A
    #   8. Nothing → scan for new work (normal mode)
    #   9. Learn from recent work

    # ── 1. Human input (always, even in focus mode) ──
    if [ "$has_new_issues" -gt 0 ]; then
        run_step "$SCRIPT_DIR/agents/product-manager.sh" "intake"
    fi
    if [ "$has_decisions" -gt 0 ]; then
        run_step "$SCRIPT_DIR/agents/product-manager.sh" "check-decisions"
    fi

    # ── 2. Staging CI failed → quality gate creates fix task ──
    if [ "$staging_ci" = "failure" ]; then
        log "  → Staging CI failed — checking quality gate"
        run_step "$SCRIPT_DIR/agents/quality-gate.sh" "check"
    fi

    # ── 3. PRs need review → review + security + ship ──
    if [ "$has_open_prs" -gt 0 ]; then
        log "  → $has_open_prs PRs open — review + ship"
        run_step "$SCRIPT_DIR/agents/test-runner.sh" "verify"
        run_step "$SCRIPT_DIR/agents/reviewer.sh" "review"
        run_step "$SCRIPT_DIR/agents/security.sh" "review"
        run_step "$SCRIPT_DIR/agents/senior-engineer.sh" "respond-reviews"
        run_step "$SCRIPT_DIR/agents/cto.sh" "review-prs"

    # ── 4. Approved items → engineer builds ──
    elif [ "$has_approved" -gt 0 ]; then
        log "  → $has_approved approved items — engineer builds"
        run_step "$SCRIPT_DIR/agents/senior-engineer.sh" "work"

    # ── 5. Planning items → CTO approves ──
    elif [ "$has_planning" -gt 0 ]; then
        log "  → $has_planning plans awaiting approval"
        run_step "$SCRIPT_DIR/agents/cto.sh" "approve-plans"

    # ── 6. Triage items → planner plans ──
    elif [ "$has_triage" -gt 0 ]; then
        log "  → $has_triage triage items — planner plans"
        run_step "$SCRIPT_DIR/agents/cto.sh" "triage"
        run_step "$SCRIPT_DIR/agents/planner.sh" "plan"

    # ── 7. Staging green, nothing in progress → quality gate ──
    elif [ "$staging_ci" = "success" ] && [ "$has_open_prs" -eq 0 ]; then
        log "  → Staging green, no work — quality gate check"
        run_step "$SCRIPT_DIR/agents/devops.sh" "deploy-verify"
        run_step "$SCRIPT_DIR/agents/sre.sh" "monitor"
        run_step "$SCRIPT_DIR/agents/quality-gate.sh" "check"

    # ── 8. Nothing to do → scan for new work (normal mode) ──
    elif [ "$focus_mode" != "true" ] && [ $((CYCLE % 5)) -eq 1 ]; then
        log "  → Nothing in progress — scanning for new work"
        run_step "$SCRIPT_DIR/agents/cto.sh" "scan"
        run_step "$SCRIPT_DIR/agents/security.sh" "scan"

    # ── 9. Truly idle ──
    else
        log "  → Nothing to do"
    fi

    # ── Learn from recent work (after dispatch, both modes) ──
    local has_merged_work
    has_merged_work=$(gh pr list --repo "$target_repo" --state merged --base "$staging_branch" --json mergedAt --jq "[.[] | select(.mergedAt > \"$(date -u -v-1H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '2000-01-01')\")]| length" 2>/dev/null || echo "0")
    if [ "$has_merged_work" -gt 0 ]; then
        run_step "$SCRIPT_DIR/agents/compound.sh" "extract"
    fi
    if [ $((CYCLE % 5)) -eq 0 ]; then
        run_step "$SCRIPT_DIR/agents/self-improve.sh" "learn"
    fi

    # ── Periodic audits (normal mode only, staggered) ──
    if [ "$focus_mode" != "true" ]; then
        case $((CYCLE % 10)) in
            1) run_step "$SCRIPT_DIR/agents/security.sh" "audit" ;;
            3) run_step "$SCRIPT_DIR/agents/docs-writer.sh" "audit" ;;
            5) run_step "$SCRIPT_DIR/agents/dependency-auditor.sh" "audit" ;;
            7) run_step "$SCRIPT_DIR/agents/accessibility-auditor.sh" "audit" ;;
            9) run_step "$SCRIPT_DIR/agents/sre.sh" "env-audit" ;;
            0) run_step "$SCRIPT_DIR/agents/qa-writer.sh" "generate" ;;
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
