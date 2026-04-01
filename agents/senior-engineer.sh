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

cd "$TARGET_PROJECT"

# Branch name from feature ID
local_branch="agent/${FEATURE_ID}-$(echo "$topic" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 30)"
base_branch="${DEPLOY_BRANCH:-staging}"

# Check if resuming
git fetch origin 2>/dev/null || true
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

feature_set_status "$FEATURE_ID" "building"
feature_set "$FEATURE_ID" "branch" "$local_branch"

# Plan already loaded before cd
impl_prompt=$(load_prompt "engineer-implement") || exit 1
impl_prompt=$(render_prompt "$impl_prompt" \
    TASK_TITLE "$topic" \
    TASK_BODY "$plan_content" \
    RESUME_CONTEXT "")

result=$(safe_claude "$AGENT" "$impl_prompt" \
--allowedTools "Bash,Read,Write,Edit,Glob,Grep") || {
    log "⚠️ Implementation failed"
    # Save partial work
    cd "$TARGET_PROJECT"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        git add -A
        git commit -m "wip: partial #$FEATURE_ID" 2>/dev/null || true
        git push -u origin "$local_branch" 2>/dev/null || true
    fi
    git checkout "$base_branch" 2>/dev/null || true
    exit 1
}

# Commit and push
cd "$TARGET_PROJECT"
if git diff --cached --quiet && git diff --quiet; then
    log "⚠️ No changes"
    git checkout "$base_branch" 2>/dev/null || true
    exit 0
fi

git add -A
git commit -m "feat: $topic (#$FEATURE_ID)" \
    -m "Co-Authored-By: AI Engineer <agent@factory>" || {
    log "⚠️ Commit failed"
    git checkout "$base_branch" 2>/dev/null || true
    exit 1
}

git push -u origin "$local_branch" || {
    log "⚠️ Push failed"
    git checkout "$base_branch" 2>/dev/null || true
    exit 1
}

# Create PR
pr_url=$(gh pr create \
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

git checkout "$base_branch" 2>/dev/null || true
log "✅ #$FEATURE_ID → PR: $pr_url"
