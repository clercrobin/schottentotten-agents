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
source "$SCRIPT_DIR/lib/sync-agents-repo.sh"
source "$SCRIPT_DIR/lib/ensure-claude-md.sh"
source "$SCRIPT_DIR/lib/test-detect.sh"

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
    local deploy_workflow="${DEPLOY_WORKFLOW:-Deploy Staging}"

    # Wait for staging deploy workflow to trigger
    log "  ⏳ Waiting for staging workflow: $deploy_workflow"
    sleep 30

    # Check latest staging deployment workflow
    local attempts=0
    while [ "$attempts" -lt 10 ]; do
        attempts=$((attempts + 1))
        local ci_status
        ci_status=$(gh run list --repo "$target_repo" --workflow "$deploy_workflow" --branch "$staging_branch" --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "unknown")

        if [ "$ci_status" = "success" ]; then
            log "  ✅ $deploy_workflow green"
            return 0
        elif [ "$ci_status" = "failure" ]; then
            log "  ❌ $deploy_workflow failed"
            return 1
        fi

        log "  ⏳ $deploy_workflow: $ci_status (attempt $attempts/10)"
        sleep 30
    done

    log "  ⚠️ $deploy_workflow didn't complete in time"
    return 1
}

# ────────────────────────────────────────────
# Process one feature through its lifecycle
# ────────────────────────────────────────────
process_feature() {
    local fid="$1"
    local t0 max_iter iter
    t0=$(date +%s)
    max_iter=20
    iter=0

    # Ensure target project has a CLAUDE.md (auto-generates if missing)
    ensure_claude_md

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
            testing)
                # Run tests on the PR branch, generate missing tests if needed
                local pr_num_test target_repo_test
                pr_num_test=$(feature_field "$fid" "pr")
                target_repo_test="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
                local branch_test
                branch_test=$(feature_field "$fid" "branch")

                if [ -z "$pr_num_test" ] || [ "$pr_num_test" = "None" ]; then
                    log "  ⚠️ No PR for testing — skipping to review"
                    feature_set_status "$fid" "review"
                    continue
                fi

                log "  🧪 Running tests on $branch_test"

                # Checkout the branch and run tests
                cd "$TARGET_PROJECT"
                git fetch origin 2>/dev/null || true
                # Branch may have been cleaned up by worktree — recreate from remote
                git branch -D "$branch_test" 2>/dev/null || true
                git checkout -b "$branch_test" "origin/$branch_test" 2>/dev/null || {
                    log "  ⚠️ Cannot checkout $branch_test — skipping to review"
                    feature_set_status "$fid" "review"
                    continue
                }

                local test_results test_exit
                test_results=$(detect_and_run_tests 2>&1)
                test_exit=$?

                if [ "$test_exit" -eq 0 ]; then
                    log "  ✅ Tests pass"
                    # Post results as PR comment
                    gh pr comment "$pr_num_test" --repo "$target_repo_test" \
                        --body "## 🧪 Test Results: ✅ ALL PASSING
$test_results" 2>/dev/null || true
                    feature_set_status "$fid" "review"
                elif [ "$test_exit" -eq 2 ]; then
                    log "  ⚠️ No test runner detected — generating tests"
                    # Run QA writer to generate tests, then re-test
                    local diff_content
                    diff_content=$(git diff "origin/${DEPLOY_BRANCH:-staging}...$branch_test" 2>/dev/null | head -c 8000)

                    local qa_prompt="Generate tests for these changes. Follow existing test patterns in the project.

## Changes
\`\`\`diff
$diff_content
\`\`\`

Write the test files. Run them to verify they pass. Stage with git add."
                    TARGET_PROJECT="$TARGET_PROJECT" safe_claude "engineer" "$qa_prompt" >/dev/null 2>&1 || true

                    # Commit + push generated tests
                    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
                        git add -u
                        git ls-files --others --exclude-standard | grep -v 'node_modules' | xargs -r git add
                        git commit -m "test: add tests for #$fid" \
                            -m "Co-Authored-By: AI QA Writer <agent@factory>" 2>/dev/null || true
                        git push 2>/dev/null || true
                        log "  🧪 Tests generated and pushed"
                    fi

                    # Re-run tests
                    test_results=$(detect_and_run_tests 2>&1)
                    test_exit=$?
                    gh pr comment "$pr_num_test" --repo "$target_repo_test" \
                        --body "## 🧪 Test Results$([ "$test_exit" -eq 0 ] && echo ': ✅ PASSING' || echo ': ⚠️ PARTIAL')
$test_results" 2>/dev/null || true
                    feature_set_status "$fid" "review"
                else
                    log "  ❌ Tests FAILED — sending back to engineer"
                    gh pr comment "$pr_num_test" --repo "$target_repo_test" \
                        --body "## 🧪 Test Results: ❌ FAILURES
$test_results

Engineer will fix." 2>/dev/null || true
                    feature_add_feedback "$fid" "test-runner" "failing" \
                        "Tests failed on branch $branch_test: $(echo "$test_results" | grep -i 'FAIL' | head -3 | tr '\n' ' ')"
                    feature_set_status "$fid" "building"
                fi
                git checkout "${DEPLOY_BRANCH:-staging}" 2>/dev/null || true
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
                    # Merge failed — likely conflict. Rebase branch onto staging and retry.
                    local branch_name
                    branch_name=$(feature_field "$fid" "branch")
                    log "  ⚠️ Merge failed — attempting rebase of $branch_name onto $staging_branch"

                    local rebase_ok=false
                    if [ -n "$branch_name" ]; then
                        cd "$TARGET_PROJECT"
                        git fetch origin 2>/dev/null
                        git checkout "$branch_name" 2>/dev/null || git checkout -b "$branch_name" "origin/$branch_name" 2>/dev/null
                        if git rebase "origin/$staging_branch" 2>/dev/null; then
                            git push --force-with-lease origin "$branch_name" 2>/dev/null && rebase_ok=true
                        else
                            git rebase --abort 2>/dev/null
                        fi
                        git checkout "$staging_branch" 2>/dev/null || true
                    fi

                    # Helper: full cleanup of stale branch/PR/worktree
                    _reset_for_fresh_build() {
                        local _fid="$1" _pr="$2" _branch="$3" _repo="$4" _base="$5"
                        log "  🧹 Full cleanup: PR#$_pr, branch=$_branch"
                        cd "$TARGET_PROJECT"
                        git checkout "$_base" 2>/dev/null || true
                        git rebase --abort 2>/dev/null || true
                        # Close stale PR + delete remote branch
                        gh pr close "$_pr" --repo "$_repo" --delete-branch 2>/dev/null || true
                        # Delete local branch
                        [ -n "$_branch" ] && git branch -D "$_branch" 2>/dev/null || true
                        # Clean up any worktree for this feature
                        local wt_dir="/tmp/agent-wt-${_fid}"
                        [ -d "$wt_dir" ] && git worktree remove "$wt_dir" --force 2>/dev/null || true
                        # Reset state — triage if feedback exists (plan needs rework), approved otherwise
                        feature_set "$_fid" "branch" ""
                        feature_set "$_fid" "pr" ""
                        local has_feedback
                        has_feedback=$(python3 -c "
import json, os
d = json.load(open(os.path.join('${_FEATURE_DIR}', '${_fid}.json')))
print('yes' if d.get('feedback') else 'no')
" 2>/dev/null || echo "no")
                        if [ "$has_feedback" = "yes" ]; then
                            feature_set_status "$_fid" "triage"
                            log "  → Reset to triage (has feedback — planner will amend plan)"
                        else
                            feature_set_status "$_fid" "approved"
                            log "  → Reset to approved (no feedback — engineer will rebuild)"
                        fi
                    }

                    if [ "$rebase_ok" = true ]; then
                        log "  🔄 Rebased — retrying merge"
                        if ! gh pr merge "$pr_num" --repo "$target_repo" --squash --delete-branch 2>/dev/null; then
                            log "  ⚠️ Merge still failed after rebase"
                            _reset_for_fresh_build "$fid" "$pr_num" "$branch_name" "$target_repo" "$staging_branch"
                        fi
                    else
                        log "  ⚠️ Rebase failed — conflict too complex"
                        _reset_for_fresh_build "$fid" "$pr_num" "$branch_name" "$target_repo" "$staging_branch"
                    fi

                    # If merge didn't succeed, loop will pick up new status (approved → engineer)
                    local merge_check
                    merge_check=$(feature_field "$fid" "status")
                    [ "$merge_check" != "reviewed" ] && continue
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
            # Stuck — agent ran but didn't advance. Add feedback and reset to triage
            # so the planner can amend the plan (likely stale or already implemented).
            log "  ⚠️ Status unchanged ($status) — agent couldn't advance"
            if [ "$status" = "building" ] || [ "$status" = "approved" ]; then
                feature_add_feedback "$fid" "pipeline" "stuck" \
                    "Engineer ran but produced no changes on status=$status. Plan may describe already-merged work or be too vague."
                # Clean up worktree/branch
                local stuck_branch stuck_wt
                stuck_branch=$(feature_field "$fid" "branch")
                stuck_wt="/tmp/agent-wt-${fid}"
                [ -d "$stuck_wt" ] && (cd "$TARGET_PROJECT" && git worktree remove "$stuck_wt" --force 2>/dev/null) || true
                [ -n "$stuck_branch" ] && (cd "$TARGET_PROJECT" && git branch -D "$stuck_branch" 2>/dev/null) || true
                feature_set "$fid" "branch" ""
                feature_set "$fid" "pr" ""
                feature_set_status "$fid" "triage"
                log "  → Reset to triage — planner will amend plan with feedback"
                continue
            fi
            break
        fi
        log "  → $status → $new_status"
        # Sync key transitions to agents repo
        case "$new_status" in
            planning)  sync_event "$fid" "📋" "Plan created" ;;
            approved)  sync_event "$fid" "✅" "Plan approved — building next" ;;
            review)    sync_event "$fid" "🔎" "PR created — reviewing" ;;
            done)      sync_event "$fid" "✅" "Merged to staging — smoke tests pass" ;;
        esac
    done

    local elapsed=$(( $(date +%s) - t0 ))
    local final
    final=$(feature_field "$fid" "status")
    log "═══ #$fid: $final in ${elapsed}s ($iter steps) ═══"

    # Sync feature board to agents repo
    sync_feature_board
}

# ────────────────────────────────────────────
# Main
# ────────────────────────────────────────────
# Check for human feedback on discussions before processing
check_human_feedback() {
    log "💬 Checking for human feedback..."
    PROJECT_NAME="$PROJECT_NAME" ENV_NAME="$ENV_NAME" \
        bash "$SCRIPT_DIR/agents/product-manager.sh" check-feedback 2>&1 | \
        tee -a "${LOG_DIR:-logs}/feature.log"
}

case "$ACTION" in
    --next)
        check_human_feedback
        fid=$(feature_find_by_status "triage" "planning" "approved" "building" "testing" "review" "reviewed")
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
            check_human_feedback
            fid=$(feature_find_by_status "triage" "planning" "approved" "building" "testing" "review" "reviewed")
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
