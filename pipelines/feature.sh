#!/bin/bash
# ============================================================
# 🔧 Feature Pipeline — Per-feature, isolated
#
# Takes ONE feature through its entire lifecycle:
#   triage → plan → approve → build → review → smoke test → merge to staging
#
# Handles failures:
#   - CTO rejects plan → planner iterates with feedback
#   - Build fails → engineer retries
#   - Smoke test fails → engineer fixes → retry
#   - Reviewer requests changes → engineer addresses
#
# Usage:
#   ./pipelines/feature.sh --project foo --env staging <feature_id>
#   ./pipelines/feature.sh --project foo --env staging --next
#   ./pipelines/feature.sh --project foo --env staging --loop
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
_AGENT_MODE="${1:-}"
set --
source "$SCRIPT_DIR/config-loader.sh"
eval "$(parse_project_flag "$@")"
eval "$(parse_env_flag "$@")"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/robust.sh"
source "$SCRIPT_DIR/lib/feature-state.sh"
source "$SCRIPT_DIR/lib/discussions.sh"

ACTION="${_AGENT_MODE:-}"
log() { echo "[$(date '+%H:%M:%S')] [FEAT] $*"; }

run_agent() {
    local agent="$1"; shift
    log "  ▶ $agent $*"
    local t0; t0=$(date +%s)
    PROJECT_NAME="$PROJECT_NAME" ENV_NAME="$ENV_NAME" \
        bash "$SCRIPT_DIR/agents/$agent" "$@" 2>&1 | tee -a "${LOG_DIR:-logs}/feature.log"
    local rc=$? elapsed=$(( $(date +%s) - t0 ))
    [ $rc -eq 0 ] && log "  ✅ $agent (${elapsed}s)" || log "  ❌ $agent (${elapsed}s)"
    return $rc
}

# ────────────────────────────────────────────
# Run smoke test on staging after merge
# Returns 0 if passing, 1 if failing
# ────────────────────────────────────────────
run_smoke_test() {
    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
    local staging_branch="${DEPLOY_BRANCH:-staging}"

    # Wait for CI to trigger
    log "  ⏳ Waiting for staging CI..."
    sleep 30

    # Check latest staging CI
    local attempts=0
    while [ "$attempts" -lt 10 ]; do
        attempts=$((attempts + 1))
        local ci_status
        ci_status=$(gh run list --repo "$target_repo" --branch "$staging_branch" --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "unknown")

        if [ "$ci_status" = "success" ]; then
            log "  ✅ Staging CI green (smoke tests passed)"
            return 0
        elif [ "$ci_status" = "failure" ]; then
            log "  ❌ Staging CI failed"
            return 1
        fi

        log "  ⏳ CI: $ci_status (attempt $attempts/10)"
        sleep 30
    done

    log "  ⚠️ CI didn't complete in time"
    return 1
}

# ────────────────────────────────────────────
# Process one feature through its lifecycle
# ────────────────────────────────────────────
process_feature() {
    local fid="$1"
    local t0 max_iter iter
    t0=$(date +%s)
    max_iter=12
    iter=0

    log "═══ Feature #$fid ═══"

    while [ "$iter" -lt "$max_iter" ]; do
        iter=$((iter + 1))
        local status topic
        status=$(feature_field "$fid" "status")
        topic=$(feature_field "$fid" "topic")

        log "  [$iter] $status | $topic"

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
                # Merge PR to staging → deploy → smoke test → iterate if failing
                local pr_num target_repo staging_branch
                pr_num=$(feature_field "$fid" "pr")
                target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
                staging_branch="${DEPLOY_BRANCH:-staging}"

                if [ -z "$pr_num" ] || [ "$pr_num" = "None" ]; then
                    log "  ⚠️ No PR — cannot merge"
                    break
                fi

                log "  🔀 Merging PR #$pr_num to $staging_branch"
                if ! gh pr merge "$pr_num" --repo "$target_repo" --squash --delete-branch 2>/dev/null; then
                    log "  ⚠️ Merge failed"
                    break
                fi
                log "  ✅ Merged to $staging_branch"

                # Wait for CI to deploy staging and run smoke tests
                log "  🧪 Waiting for staging deploy + smoke tests..."
                if run_smoke_test; then
                    feature_set_status "$fid" "done"
                    local discussion
                    discussion=$(feature_field "$fid" "discussion")
                    [ -n "$discussion" ] && [ "$discussion" != "null" ] && \
                        reply_to_discussion "$discussion" \
                        "✅ **Merged to $staging_branch. CI + smoke tests pass.**" \
                        "🔧 Feature Pipeline" 2>/dev/null || true
                    log "  ✅ Staging green — feature complete"
                else
                    # Smoke failed — get error, send back to engineer
                    log "  🔄 Smoke test FAILED — sending back to engineer"
                    local run_id error_context
                    run_id=$(gh run list --repo "$target_repo" --branch "$staging_branch" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
                    error_context=$(gh run view "$run_id" --repo "$target_repo" --log-failed 2>/dev/null | tail -25)

                    feature_add_feedback "$fid" "smoke-test" "failing" \
                        "Staging smoke test failed after merge to $staging_branch. CI run: $run_id. Error: $(echo "$error_context" | head -10 | tr '\n' ' ')"

                    # Engineer needs to fix ON the staging branch directly
                    # (PR was already merged, so new fix goes as a new commit)
                    feature_set "$fid" "branch" "$staging_branch"
                    feature_set_status "$fid" "building"
                    log "  → Status back to building — engineer will fix and push to $staging_branch"
                fi
                ;;
            done)
                break
                ;;
            *)
                log "  ❓ Unknown: $status"
                break
                ;;
        esac

        # Check transition
        local new_status
        new_status=$(feature_field "$fid" "status")
        if [ "$new_status" = "done" ]; then
            break
        fi
        if [ "$new_status" = "$status" ]; then
            log "  ⚠️ Status unchanged ($status) — stopping"
            break
        fi
        log "  → $status → $new_status"
    done

    local elapsed=$(( $(date +%s) - t0 ))
    local final
    final=$(feature_field "$fid" "status")
    log "═══ #$fid: $final in ${elapsed}s ($iter steps) ═══"
}

# ────────────────────────────────────────────
# Main
# ────────────────────────────────────────────
case "$ACTION" in
    --next)
        fid=$(feature_find_by_status "triage" "planning" "approved" "building" "review" "reviewed")
        if [ -n "$fid" ]; then
            process_feature "$fid"
        else
            log "No features to process"
        fi
        ;;
    --loop)
        log "🔁 Feature pipeline loop"
        trap 'log "🛑 Stopping"; pkill -P $$ 2>/dev/null; exit 0' INT TERM
        while true; do
            fid=$(feature_find_by_status "triage" "planning" "approved" "building" "review" "reviewed")
            if [ -n "$fid" ]; then
                process_feature "$fid"
            else
                log "💤 No features — sleeping 30s"
                sleep 30
            fi
        done
        ;;
    --help|-h|"")
        echo "🔧 Feature Pipeline"
        echo "  ./pipelines/feature.sh --project <name> --env <env> <feature_id>"
        echo "  ./pipelines/feature.sh --project <name> --env <env> --next"
        echo "  ./pipelines/feature.sh --project <name> --env <env> --loop"
        echo ""
        feature_list
        ;;
    *)
        process_feature "$ACTION"
        ;;
esac
