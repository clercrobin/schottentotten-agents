#!/bin/bash
# ============================================================
# 👷 Senior Engineer Agent — Stateful version
#
# Receives feature ID. Reads plan from disk. Implements. Updates state.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_AGENT_MODE="${1:-}"
set --
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"
source "$SCRIPT_DIR/../lib/feature-state.sh"

FEATURE_ID="${_AGENT_MODE:-}"
AGENT="engineer"
log() { echo "[$(date '+%H:%M:%S')] [ENG] $*"; }

[ -z "$FEATURE_ID" ] && { log "No feature ID"; exit 1; }

topic=$(feature_field "$FEATURE_ID" "topic")
plan_file=$(feature_field "$FEATURE_ID" "plan")
discussion=$(feature_field "$FEATURE_ID" "discussion")
status=$(feature_field "$FEATURE_ID" "status")

log "👷 Building #$FEATURE_ID: $topic (status=$status)"

[ ! -f "$plan_file" ] && { log "No plan file: $plan_file"; exit 1; }

# Plan is in TARGET_PROJECT/docs/plans/ — read it directly
plan_content=$(cat "$plan_file" 2>/dev/null || echo "")
[ -z "$plan_content" ] && { log "⚠️ Empty plan file: $plan_file"; exit 1; }
log "  Plan: ${#plan_content} chars"

# Branch name from feature ID
local_branch="agent/${FEATURE_ID}-$(echo "$topic" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 30)"
base_branch="${DEPLOY_BRANCH:-staging}"
use_worktree="${USE_WORKTREE:-true}"
work_dir=""
# Check if state has a branch — empty means pipeline reset (fresh build needed)
state_branch=$(feature_field "$FEATURE_ID" "branch")
fresh_build=false
[ -z "$state_branch" ] || [ "$state_branch" = "null" ] || [ "$state_branch" = "None" ] && fresh_build=true

cd "$TARGET_PROJECT"
git fetch origin 2>/dev/null || true

# ── Set up working directory (worktree or branch checkout) ──
if [ "$use_worktree" = "true" ]; then
    # Worktree: isolated copy — enables parallel features without branch conflicts
    work_dir="/tmp/agent-wt-${FEATURE_ID}"

    # Fresh build: clean any stale worktree + local/remote branch from previous iteration
    if [ "$fresh_build" = true ]; then
        [ -d "$work_dir" ] && {
            log "  Cleaning stale worktree for fresh build"
            git worktree remove "$work_dir" --force 2>/dev/null || rm -rf "$work_dir"
        }
        git branch -D "$local_branch" 2>/dev/null || true
        git push origin --delete "$local_branch" 2>/dev/null || true
    fi

    if [ -d "$work_dir" ]; then
        log "  Resuming worktree $work_dir"
        cd "$work_dir"
        git pull --ff-only 2>/dev/null || true
    elif [ "$fresh_build" != true ] && git rev-parse "origin/$local_branch" >/dev/null 2>&1; then
        log "  Worktree from remote $local_branch"
        git worktree add "$work_dir" "origin/$local_branch" 2>/dev/null || \
            git worktree add -b "$local_branch" "$work_dir" "origin/$local_branch"
        cd "$work_dir"
        git checkout -B "$local_branch" "origin/$local_branch" 2>/dev/null || true
    else
        log "  New worktree $local_branch from $base_branch"
        git branch -D "$local_branch" 2>/dev/null || true
        git worktree add -b "$local_branch" "$work_dir" "origin/$base_branch" 2>/dev/null || {
            log "Cannot create worktree"; exit 1
        }
        cd "$work_dir"
    fi
else
    # Legacy: checkout branch in main working copy
    work_dir="$TARGET_PROJECT"
    if git rev-parse "origin/$local_branch" >/dev/null 2>&1; then
        log "  Resuming from remote $local_branch"
        git checkout "$local_branch" 2>/dev/null || git checkout -b "$local_branch" "origin/$local_branch"
        git pull --ff-only 2>/dev/null || true
    elif git rev-parse "$local_branch" >/dev/null 2>&1; then
        log "  Resuming from local $local_branch"
        git checkout "$local_branch" 2>/dev/null
    else
        log "  Creating $local_branch from $base_branch"
        git checkout "$base_branch" 2>/dev/null || true
        git pull origin "$base_branch" 2>/dev/null || true
        git checkout -b "$local_branch" || { log "Cannot create branch"; exit 1; }
    fi
fi

feature_set_status "$FEATURE_ID" "building"
feature_set "$FEATURE_ID" "branch" "$local_branch"
_ORIG_TARGET_PROJECT="$TARGET_PROJECT"

# Dynamic context — engineer agent definition provides system prompt
impl_prompt="## $topic

## Implementation Plan
$plan_content"

# Run Claude in the work directory (worktree or main checkout)
TARGET_PROJECT="$work_dir" result=$(safe_claude "engineer" "$impl_prompt") || {
    log "⚠️ Implementation failed"
    # Save partial work
    cd "$work_dir"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        git add -u
        git ls-files --others --exclude-standard | grep -v 'node_modules' | xargs -r git add
        git commit -m "wip: partial #$FEATURE_ID" 2>/dev/null || true
        git push -u origin "$local_branch" 2>/dev/null || true
    fi
    [ "$use_worktree" != "true" ] && git checkout "$base_branch" 2>/dev/null || true
    exit 1
}

# Commit and push
cd "$work_dir"
if git diff --cached --quiet && git diff --quiet; then
    log "⚠️ No changes"
    [ "$use_worktree" != "true" ] && git checkout "$base_branch" 2>/dev/null || true
    exit 0
fi

# Stage tracked changes only (avoid accidentally committing symlinks, node_modules etc.)
git add -u
# Also stage new files, but exclude common noise
git ls-files --others --exclude-standard | grep -v 'node_modules' | grep -v '.agents/' | xargs -r git add
git commit -m "feat: $topic (#$FEATURE_ID)" \
    -m "Co-Authored-By: AI Engineer <agent@factory>" || {
    log "⚠️ Commit failed"
    [ "$use_worktree" != "true" ] && git checkout "$base_branch" 2>/dev/null || true
    exit 1
}

git push -u origin "$local_branch" || {
    log "⚠️ Push failed"
    [ "$use_worktree" != "true" ] && git checkout "$base_branch" 2>/dev/null || true
    exit 1
}

# Create PR — use original TARGET_PROJECT (not worktree path) for repo name
target_repo="${GITHUB_OWNER}/$(basename "${_ORIG_TARGET_PROJECT:-$TARGET_PROJECT}")"
pr_url=$(gh pr create \
    --repo "$target_repo" \
    --title "$topic" \
    --body "Implementation for feature #$FEATURE_ID.

$result" \
    --base "$base_branch" \
    --head "$local_branch" 2>&1 | tail -1) || pr_url="(PR failed)"

# Extract PR number
pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "")

# Update state
feature_set_status "$FEATURE_ID" "review"
[ -n "$pr_num" ] && feature_set "$FEATURE_ID" "pr" "$pr_num"

# Post summary to Discussion
[ -n "$discussion" ] && [ "$discussion" != "null" ] && \
    reply_to_discussion "$discussion" "👷 **Implemented.** PR: $pr_url" "$AGENT" 2>/dev/null || true

# Cleanup
if [ "$use_worktree" = "true" ]; then
    cd "$TARGET_PROJECT"
    git worktree remove "$work_dir" 2>/dev/null || true
    log "  Worktree cleaned up"
else
    git checkout "$base_branch" 2>/dev/null || true
fi
log "✅ #$FEATURE_ID → PR: $pr_url"
