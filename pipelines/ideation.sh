#!/bin/bash
# ============================================================
# 💡 Ideation Pipeline — Global, site-level
#
# Sources of ideas:
#   1. Your Discussion Ideas (always processed)
#   2. CTO codebase scan (when triggered)
#   3. Security scan (when triggered)
#
# Output: state/features/*.json files in "triage" status
# Gate: you approve/reject via Discussion reply
#
# Usage:
#   ./pipelines/ideation.sh --project foo --env staging           # check your Ideas
#   ./pipelines/ideation.sh --project foo --env staging --scan    # also scan codebase
#   ./pipelines/ideation.sh --project foo --env staging --loop    # continuous
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Save args before config-loader clears them
_ALL_ARGS=("$@")
_AGENT_MODE="${_ALL_ARGS[-1]:-}"
# Strip flags to get just the action
for _a in "${_ALL_ARGS[@]}"; do case "$_a" in --project|--env) ;; -*) _AGENT_MODE="$_a" ;; *) _AGENT_MODE="$_a" ;; esac; done
set --
source "$SCRIPT_DIR/config-loader.sh"
eval "$(parse_project_flag "${_ALL_ARGS[@]}")"
eval "$(parse_env_flag "${_ALL_ARGS[@]}")"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/robust.sh"
source "$SCRIPT_DIR/lib/feature-state.sh"
source "$SCRIPT_DIR/lib/discussions.sh"
source "$SCRIPT_DIR/lib/ensure-claude-md.sh"

# Ensure target project has a CLAUDE.md before any agent runs
ensure_claude_md

ACTION="${_AGENT_MODE:-}"
log() { echo "[$(date '+%H:%M:%S')] [IDEA] $*"; }

run_agent() {
    local agent="$1"; shift
    log "  ▶ $agent $*"
    local t0; t0=$(date +%s)
    PROJECT_NAME="$PROJECT_NAME" ENV_NAME="$ENV_NAME" \
        bash "$SCRIPT_DIR/agents/$agent" "$@" 2>&1 | tee -a "${LOG_DIR:-logs}/ideation.log"
    local rc=$? elapsed=$(( $(date +%s) - t0 ))
    [ $rc -eq 0 ] && log "  ✅ $agent (${elapsed}s)" || log "  ❌ $agent (${elapsed}s)"
    return $rc
}

run_intake() {
    log "💡 Checking for new ideas..."
    run_agent "product-manager.sh" "intake"
    run_agent "product-manager.sh" "check-decisions"

    local new_count
    new_count=$(feature_count "triage")
    log "  Triage queue: $new_count features"
}

run_scan() {
    log "🔍 Scanning codebase on ${DEPLOY_BRANCH:-staging} branch..."
    # Ensure we scan the staging branch (latest code, not prod)
    cd "$TARGET_PROJECT"
    git fetch origin 2>/dev/null || true
    git checkout "${DEPLOY_BRANCH:-staging}" 2>/dev/null || true
    git pull 2>/dev/null || true
    cd "$SCRIPT_DIR"

    run_agent "cto.sh" "scan"
    run_agent "security.sh" "scan"
}

case "$ACTION" in
    --scan)
        run_intake
        run_scan
        ;;
    --loop)
        log "🔁 Ideation loop — checks every 2 min"
        trap 'log "🛑 Stopping"; exit 0' INT TERM
        local cycle=0
        while true; do
            cycle=$((cycle + 1))
            run_intake
            # Scan every 10 cycles (~20 min)
            if [ $((cycle % 10)) -eq 1 ]; then
                run_scan
            fi
            sleep 120
        done
        ;;
    --help|-h)
        echo "💡 Ideation Pipeline"
        echo "  ./pipelines/ideation.sh --project <name> --env <env>"
        echo "  ./pipelines/ideation.sh --project <name> --env <env> --scan"
        echo "  ./pipelines/ideation.sh --project <name> --env <env> --loop"
        ;;
    *)
        run_intake
        ;;
esac
