#!/bin/bash
# ============================================================
# 👷 Senior Engineer Agent — robust version (bash 3.2 compatible)
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/lifecycle.sh" 2>/dev/null || true
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-work}"
AGENT="engineer"

log() { echo "[$(date '+%H:%M:%S')] [ENG] $*"; }

# ────────────────────────────────────────────
# work — Pick up a task from Triage and implement it
# ────────────────────────────────────────────
run_work() {
    log "👷 Looking for approved plans..."

    # Pick up items with [APPROVED] in title from Triage
    local plans
    # Query ALL open discussions (Ideas from humans may not be in Triage category)
    plans=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        discussions(first: 20, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes { number title body comments(first: 5) { nodes { body } } }
        }
      }
    }' --jq '.data.repository.discussions.nodes' 2>/dev/null)
    plans=$(printf '%s' "$plans" | python3 -c "
import sys, json
raw = sys.stdin.read().translate({i: None for i in range(32) if i not in (9, 10, 13)})
try: print(json.dumps(json.loads(raw)))
except: print('[]')
" 2>/dev/null || echo "[]")

    # Find items in APPROVED status (title contains [APPROVED])
    local candidates
    candidates=$(echo "$plans" | python3 -c "
import sys, json
try:
    discussions = json.load(sys.stdin)
    for d in discussions:
        if '[APPROVED]' in d.get('title', ''):
            print(json.dumps(d))
except (json.JSONDecodeError, KeyError):
    pass
" 2>/dev/null)

    if [ -z "$candidates" ]; then
        log "No approved plans to implement."
        return 0
    fi

    local task_json=""
    local task_num=""

    while IFS= read -r candidate; do
        [ -z "$candidate" ] && continue
        local cand_num
        cand_num=$(echo "$candidate" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin)['number'])
except (KeyError, json.JSONDecodeError):
    sys.exit(1)
" 2>/dev/null) || continue
        if true; then  # Title status [APPROVED] is the gate
            task_json="$candidate"
            task_num="$cand_num"
            break
        fi
    done <<< "$candidates"

    if [ -z "$task_num" ]; then
        log "No new approved plans."
        return 0
    fi

    local task_title task_body
    task_title=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])" 2>/dev/null) || { log "Cannot parse task title"; return 1; }
    task_body=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])" 2>/dev/null) || task_body="(no body)"

    log "🎯 Picked up approved plan #$task_num: $task_title"

    # Advance status to BUILDING
    local topic
    topic=$(extract_topic "$task_title" 2>/dev/null || echo "$task_title")
    advance_status "$task_num" "BUILDING" "$topic" "🏗️ Starting implementation." "$AGENT_SENIOR_ENG" 2>/dev/null || true

    cd "$TARGET_PROJECT"
    # Use DEPLOY_BRANCH (staging) as base — PRs never target main directly
    local base_branch="${DEPLOY_BRANCH:-staging}"

    # Deterministic branch name (same across retries for resumability)
    local branch_name
    branch_name="agent/$(echo "$task_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 50)"

    # Check if this is a RESUME (branch already exists with prior work)
    local is_resume="false"
    local resume_context=""
    git fetch origin 2>/dev/null || true

    if git rev-parse "origin/$branch_name" >/dev/null 2>&1; then
        # Remote branch exists — resume from it
        is_resume="true"
        log "🔄 Resuming — branch $branch_name already exists on remote"

        # Ensure clean state
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            git checkout -- . 2>/dev/null || true
            git clean -fd 2>/dev/null || true
        fi

        git checkout "$branch_name" 2>/dev/null || git checkout -b "$branch_name" "origin/$branch_name"
        git pull --ff-only 2>/dev/null || true

        # Build context about prior work
        local prior_diff
        prior_diff=$(git diff "$base_branch"..."$branch_name" --stat 2>/dev/null || echo "(no diff)")
        local prior_commits
        prior_commits=$(git log "$base_branch".."$branch_name" --oneline 2>/dev/null || echo "(no commits)")
        resume_context="
IMPORTANT: This is a CONTINUATION of a previous attempt that was interrupted.
Prior work is already committed on this branch:

Commits so far:
$prior_commits

Files changed so far:
$prior_diff

Review what's already done, then COMPLETE the remaining work. Do NOT redo work that's already been done."
    else
        # Fresh start
        reply_to_discussion "$task_num" "🏗️ **Picking up this task.** Starting implementation." "$AGENT_SENIOR_ENG" || true

        # Ensure clean state before branching
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            log "⚠️  Working tree dirty — stashing changes"
            git stash push -m "agent-factory-auto-stash-$(date +%s)" || {
                log "❌ Cannot stash dirty tree"
                reply_to_discussion "$task_num" "⚠️ Working tree has uncommitted changes. Skipping." "$AGENT_SENIOR_ENG" || true
                return 1
            }
        fi

        git checkout "$base_branch" || {
            log "❌ Cannot checkout $base_branch"
            return 1
        }

        git fetch origin "$base_branch" 2>/dev/null || true
        git pull --ff-only || {
            log "⚠️  Pull failed. Attempting reset to origin."
            if git rev-parse "origin/$base_branch" >/dev/null 2>&1; then
                git reset --hard "origin/$base_branch"
            else
                log "❌ origin/$base_branch does not exist. Continuing on current HEAD."
            fi
        }

        git checkout -b "$branch_name" || {
            log "❌ Cannot create branch"
            return 1
        }
    fi

    # Implement
    log "🔧 Implementing (resume=$is_resume)..."
    local impl_prompt
    impl_prompt=$(load_prompt "engineer-implement") || { log "Cannot load engineer-implement prompt"; return 1; }
    impl_prompt=$(render_prompt "$impl_prompt" \
        TASK_TITLE "$task_title" \
        TASK_BODY "$task_body" \
        RESUME_CONTEXT "$resume_context")

    local result
    result=$(safe_claude "$AGENT" "$impl_prompt" \
    --allowedTools "Bash,Read,Write,Edit,Glob,Grep") || {
        log "⚠️  Implementation failed or timed out"

        # Save partial work instead of discarding it
        cd "$TARGET_PROJECT"
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            log "💾 Saving partial work as WIP commit..."
            git add -A
            git commit -m "wip: partial progress on #$task_num" \
                -m "Task: $task_title" \
                -m "Interrupted — will resume next cycle." || true
            git push -u origin "$branch_name" 2>/dev/null || true
            reply_to_discussion "$task_num" "⏳ Implementation timed out — partial work saved on branch \`$branch_name\`. Will resume next cycle." "$AGENT_SENIOR_ENG" || true
        else
            reply_to_discussion "$task_num" "⚠️ Implementation attempt failed. Will retry next cycle." "$AGENT_SENIOR_ENG" || true
            git checkout "$base_branch" 2>/dev/null || true
            git branch -D "$branch_name" 2>/dev/null || true
        fi
        return 1
    }

    # Commit
    cd "$TARGET_PROJECT"
    if git diff --cached --quiet && git diff --quiet; then
        log "⚠️  No changes produced"
        reply_to_discussion "$task_num" "⚠️ Analyzed but no code changes needed." "$AGENT_SENIOR_ENG" || true
        git checkout "$base_branch" 2>/dev/null || true
        git branch -D "$branch_name" 2>/dev/null || true
        mark_processed "$task_num" "$AGENT" "implemented"
        return 0
    fi

    git add -A
    git commit -m "feat: $(echo "$task_title" | sed 's/\[.*\] //')" \
        -m "Task: Discussion #$task_num" \
        -m "Co-Authored-By: AI Senior Engineer <agent@factory>" || {
        log "⚠️  Commit failed"
        git checkout "$base_branch" 2>/dev/null || true
        return 1
    }

    # Push
    git push -u origin "$branch_name" || {
        log "❌ Push failed."
        reply_to_discussion "$task_num" "⚠️ Code committed locally but push failed." "$AGENT_SENIOR_ENG" || true
        mark_processed "$task_num" "$AGENT" "implemented"
        git checkout "$base_branch" 2>/dev/null || true
        return 1
    }

    # Open PR
    local pr_url=""
    pr_url=$(gh pr create \
        --title "$(echo "$task_title" | sed 's/\[.*\] //')" \
        --body "Automated implementation for Discussion #$task_num.

$result

---
*AI Agent Factory*" \
        --base "$base_branch" \
        --head "$branch_name" 2>&1 | tail -1) || {
        log "⚠️  PR creation failed — branch pushed but no PR"
        pr_url="(PR failed — branch \`$branch_name\` pushed)"
    }

    # Post to Engineering + Code Review channels
    # Advance to REVIEW status on the original triage discussion
    advance_status "$task_num" "REVIEW" "$topic" \
"🏗️ **Implementation complete.**

**Branch:** \`$branch_name\`
**PR:** $pr_url

$result

*Awaiting code review + security review.*" "$AGENT_SENIOR_ENG" 2>/dev/null || true

    mark_processed "$task_num" "$AGENT" "implemented"
    log "✅ Implemented #$task_num → PR: $pr_url"

    git checkout "$base_branch" 2>/dev/null || true
}

# ────────────────────────────────────────────
# respond-reviews — Address code review feedback
# ────────────────────────────────────────────
run_respond_reviews() {
    log "📝 Checking for review feedback..."

    local unprocessed
    unprocessed=$(get_unprocessed "$CAT_CODE_REVIEW" "$AGENT_SENIOR_ENG") || return 0

    # Tab-separated output
    echo "$unprocessed" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    has_review = any('Code Reviewer' in c for c in d.get('comments', []))
    if has_review:
        title = d['title'].replace('\t', ' ')
        print(f\"{d['number']}\t{title}\")
" 2>/dev/null | while IFS=$'\t' read -r num title; do
        [ -z "$num" ] && continue

        is_processed "$num" "$AGENT" "review-responded" && continue

        log "Responding to review #$num"

        local disc_data feedback
        disc_data=$(get_discussions "$CAT_CODE_REVIEW" 20 | python3 -c "
import sys, json
try:
    for d in json.load(sys.stdin):
        if d['number'] == $num:
            print(json.dumps(d))
            break
except (json.JSONDecodeError, KeyError):
    pass
" 2>/dev/null)
        feedback=$(echo "$disc_data" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('\n---\n'.join(d.get('last_comments', [])))
except (json.JSONDecodeError, KeyError):
    pass
" 2>/dev/null)

        # Extract branch name from the discussion body so we commit on the right branch
        local branch_name
        branch_name=$(echo "$disc_data" | python3 -c "
import sys, json, re
try:
    d = json.load(sys.stdin)
    body = d.get('body', '')
    m = re.search(r'Branch:\*{0,2}\s*\x60([^\x60]+)\x60', body)
    if m:
        print(m.group(1))
except (json.JSONDecodeError, KeyError):
    pass
" 2>/dev/null)

        if [ -z "$branch_name" ]; then
            log "⚠️  Cannot find branch name in discussion #$num — skipping"
            continue
        fi

        # Checkout the PR branch before making changes
        cd "$TARGET_PROJECT"
        git fetch origin "$branch_name" 2>/dev/null || true
        git checkout "$branch_name" 2>/dev/null || {
            log "⚠️  Cannot checkout branch $branch_name"
            continue
        }

        local respond_prompt
        respond_prompt=$(load_prompt "engineer-respond") || continue
        respond_prompt=$(render_prompt "$respond_prompt" \
            FEEDBACK "$feedback")

        local response
        response=$(safe_claude "$AGENT" "$respond_prompt" \
        --allowedTools "Bash,Read,Write,Edit,Glob,Grep") || {
            local base_branch
            base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || echo "main")
            git checkout "$base_branch" 2>/dev/null || true
            continue
        }

        # Commit + push if there are changes
        cd "$TARGET_PROJECT"
        if ! git diff --cached --quiet || ! git diff --quiet; then
            git add -A
            git commit -m "fix: address review feedback for #$num" \
                -m "Co-Authored-By: AI Senior Engineer <agent@factory>" || true
            git push || true
        fi

        # Return to base branch
        local base_branch
        base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || echo "main")
        git checkout "$base_branch" 2>/dev/null || true

        reply_to_discussion "$num" "📝 **Feedback addressed.**

$response" "$AGENT_SENIOR_ENG" || true
        mark_processed "$num" "$AGENT" "review-responded"
        log "✅ Responded to #$num"
    done
}

case "$MODE" in
    work)            run_work ;;
    respond-reviews) run_respond_reviews ;;
    *)               echo "Usage: $0 {work|respond-reviews}"; exit 1 ;;
esac
