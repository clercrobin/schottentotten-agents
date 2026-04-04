#!/bin/bash
# ============================================================
# 🎯 CTO Agent — robust version (bash 3.2 compatible)
# ============================================================
set -uo pipefail
# NOTE: no set -e — we handle errors explicitly

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_AGENT_MODE="${1:-}"
set --
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/lifecycle.sh" 2>/dev/null || true
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"
source "$SCRIPT_DIR/../lib/feature-state.sh"

MODE="${_AGENT_MODE:-scan}"
AGENT="cto"

log() { echo "[$(date '+%H:%M:%S')] [CTO] $*"; }

# ────────────────────────────────────────────
# scan — Find issues in codebase, post to Triage
# ────────────────────────────────────────────
run_scan() {
    log "🔍 Scanning codebase..."
    log "  target: ${TARGET_PROJECT:-.}"

    # Dynamic context — CTO agent definition provides base system prompt
    local prompt_text="Analyze this codebase. Find the single most important NEW issue with the highest compound value.

Check: bugs, security (OWASP), performance, missing tests, architecture issues, TODO/FIXME debt.
Check environment health: separate TF states per env, env-specific IAM roles, no cross-env references.
Check agent tooling: can tests/linters/type-checks run?

Output a JSON array: [{\"title\": \"...\", \"priority\": \"critical|high|medium|low\", \"category\": \"bug|security|performance|quality|architecture\", \"description\": \"...\", \"files\": [\"...\"], \"suggested_approach\": \"...\"}]

**Max 1 issue.** Output empty array [] if all issues are already tracked."

    local scan_result
    scan_result=$(safe_claude "cto" "$prompt_text") || {
        log "⚠️  Claude scan failed (exit=$?)"
        return 1
    }

    local result_len=${#scan_result}
    log "📝 Scan returned ${result_len} chars"
    if [ "$result_len" -lt 10 ]; then
        log "⚠️  Scan result too short, skipping parse"
        log "  raw output: $scan_result"
        return 1
    fi

    # Parse issues via Python, post each one
    local issue_count
    issue_count=$(echo "$scan_result" | python3 -c "
import sys, json

text = sys.stdin.read()
try:
    start = text.index('[')
    end = text.rindex(']') + 1
    issues = json.loads(text[start:end])
    print(len(issues))
except (ValueError, json.JSONDecodeError) as e:
    print(f'0', end='')
    print(f'JSON parse error: {e}', file=sys.stderr)
" 2>&1)
    log "📊 Found ${issue_count} issues in scan result"

    # Write issues as JSONL (one JSON object per line) to a temp file
    local issues_file
    issues_file=$(mktemp)

    echo "$scan_result" | python3 -c "
import sys, json

text = sys.stdin.read()
try:
    start = text.index('[')
    end = text.rindex(']') + 1
    issues = json.loads(text[start:end])
except (ValueError, json.JSONDecodeError):
    sys.exit(0)

for issue in issues[:5]:
    title = f'[{issue[\"priority\"].upper()}] {issue[\"title\"]}'
    body = '\n'.join([
        f'**Priority:** {issue[\"priority\"]}',
        f'**Category:** {issue[\"category\"]}',
        f'**Files:** {\", \".join(issue.get(\"files\", [\"unknown\"]))}',
        '',
        issue['description'],
        '',
        f'**Suggested approach:** {issue[\"suggested_approach\"]}'
    ])
    print(json.dumps({'title': title, 'body': body}))
" > "$issues_file" 2>/dev/null

    # Get existing open triage titles for dedup
    local existing_titles
    existing_titles=$(get_discussions "$CAT_TRIAGE" 50 2>/dev/null | python3 -c "
import sys, json
try:
    for d in json.load(sys.stdin):
        print(d.get('title', '').lower())
except: pass
" 2>/dev/null)

    local posted=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue

        local title body
        title=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
        body=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])")

        # Dedup: skip if a similar title already exists
        local title_lower
        title_lower=$(echo "$title" | tr '[:upper:]' '[:lower:]')
        if echo "$existing_titles" | grep -qF "$title_lower"; then
            log "⏭️  Already tracked: $title"
            continue
        fi

        log "📤 Posting issue: $title"
        local disc_num
        disc_num=$(create_triage "$title" "$body" "$AGENT_CTO") || {
            log "⚠️  Failed to post discussion for: $title"
            continue
        }
        mark_processed "$disc_num" "$AGENT" "created"
        log "📋 Created #$disc_num: $title"
        posted=$((posted + 1))
    done < "$issues_file"

    rm -f "$issues_file"
    log "✅ Scan complete — posted $posted issues"
}

# ────────────────────────────────────────────
# triage — Review engineering discussions
# ────────────────────────────────────────────
run_triage() {
    log "📋 Triaging..."

    local unprocessed
    unprocessed=$(get_unprocessed "$CAT_ENGINEERING" "$AGENT_CTO") || return 0

    # Use tab as delimiter — safe for titles/bodies
    echo "$unprocessed" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    # tab-separated: number, title, body (truncated)
    body = d['body'][:500].replace('\t', ' ').replace('\n', ' ')
    title = d['title'].replace('\t', ' ')
    print(f\"{d['number']}\t{title}\t{body}\")
" 2>/dev/null | while IFS=$'\t' read -r num title body; do
        [ -z "$num" ] && continue

        is_processed "$num" "$AGENT" "triaged" && continue

        log "Reviewing #$num"

        # Dynamic context — CTO agent definition provides system prompt
        local triage_prompt="Review Discussion #$num: $title

$body

Provide technical assessment and priority recommendation."

        local response
        response=$(safe_claude "cto" "$triage_prompt") || continue

        reply_to_discussion "$num" "$response" "$AGENT_CTO" || continue
        mark_processed "$num" "$AGENT" "triaged"
        log "✅ Triaged #$num"
    done
}

# ────────────────────────────────────────────
# review-prs — Check CI + review status, then merge
#
# Uses GitHub CI check results as the gate (not the local
# test-runner agent). This is the source of truth.
# ────────────────────────────────────────────
run_review_prs() {
    log "🔀 Checking for mergeable PRs..."

    # Get all open PRs from the TARGET project repo (not the agents repo)
    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
    local open_prs
    open_prs=$(gh pr list --repo "$target_repo" --state open --json number,title,headRefName,statusCheckRollup,reviews --limit 30 2>/dev/null) || {
        log "⚠️  Cannot list PRs from $target_repo"
        return 0
    }

    local pr_count
    pr_count=$(echo "$open_prs" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    log "  Found $pr_count open PRs"

    echo "$open_prs" | python3 -c "
import sys, json

prs = json.load(sys.stdin)
for pr in prs:
    # Check CI status
    checks = pr.get('statusCheckRollup', []) or []
    ci_pass = False
    if checks:
        conclusions = [c.get('conclusion','') for c in checks if c.get('conclusion')]
        ci_pass = len(conclusions) > 0 and all(c == 'SUCCESS' for c in conclusions)

    # Check if it's an agent PR
    branch = pr.get('headRefName', '')
    is_agent = branch.startswith('agent/')

    if is_agent and ci_pass:
        title = pr['title'].replace('\t', ' ')
        print(f\"{pr['number']}\t{title}\t{branch}\")
" 2>/dev/null | while IFS=$'\t' read -r pr_num title branch; do
        [ -z "$pr_num" ] && continue

        is_processed "$pr_num" "$AGENT" "pr-merged" && continue

        log "🟢 PR #$pr_num CI ✅: $title"

        # Also check the agents repo discussion for reviewer approval
        local reviews
        reviews=$(get_discussions "$CAT_CODE_REVIEW" 20) || reviews="[]"
        local has_review_approval
        has_review_approval=$(echo "$reviews" | python3 -c "
import sys, json
found = False
for d in json.load(sys.stdin):
    if '$branch' in d.get('body', '') or '#$pr_num' in d.get('body', ''):
        comments = ' '.join(d.get('last_comments', []))
        if 'APPROVED' in comments.upper():
            found = True
            break
print('yes' if found else 'no')
" 2>/dev/null)

        if [ "$has_review_approval" != "yes" ]; then
            log "  ⏳ PR #$pr_num — CI passes but no reviewer approval yet, skipping"
            continue
        fi

        # Security gate: check for security blocks
        local has_security_block
        has_security_block=$(echo "$reviews" | python3 -c "
import sys, json
blocked = False
for d in json.load(sys.stdin):
    if '$branch' in d.get('body', '') or '#$pr_num' in d.get('body', ''):
        comments = ' '.join(d.get('last_comments', []))
        if 'security-blocked' in comments.lower() or 'SECURITY BLOCK' in comments:
            blocked = True
            break
print('yes' if blocked else 'no')
" 2>/dev/null)

        if [ "$has_security_block" = "yes" ]; then
            log "  🚫 PR #$pr_num — SECURITY BLOCKED, cannot merge"
            continue
        fi

        # DO NOT MERGE TO MAIN — only the human merges to main.
        # Tag as approved so DevOps staging picks it up.
        log "  ✅ PR #$pr_num approved for staging (CI ✅ + review ✅ + security ✅)"

        # Label the PR so it's visible
        gh pr edit "$pr_num" --repo "$target_repo" --add-label "staging-approved" 2>/dev/null || true

        post_discussion "$CAT_ENGINEERING" "✅ Approved for staging: $title" \
"**PR:** #$pr_num | **Branch:** \`$branch\`
**CI:** ✅ | **Review:** ✅ | **Security:** ✅

This PR will be included in the next staging branch rebuild.
**Merging to main (prod) is a human decision.**" "$AGENT_CTO" || true

        mark_processed "$pr_num" "$AGENT" "pr-merged"
    done

    # Also handle the old discussion-based flow for backwards compat
    local disc_reviews
    disc_reviews=$(get_discussions "$CAT_CODE_REVIEW" 10) || return 0

    echo "$disc_reviews" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    comments = ' '.join(d.get('last_comments', []))
    has_approval = 'APPROVED' in comments.upper() or 'LGTM' in comments.upper()
    if has_approval:
        title = d['title'].replace('\t', ' ')
        print(f\"{d['number']}\t{title}\")
" 2>/dev/null | while IFS=$'\t' read -r num title; do
        [ -z "$num" ] && continue
        is_processed "$num" "$AGENT" "merged" && continue
        tag_discussion "$num" "merged" || true
        mark_processed "$num" "$AGENT" "merged"
    done
}

# ────────────────────────────────────────────
# standup
# ────────────────────────────────────────────
run_standup() {
    log "📊 Posting standup..."

    local today_cto today_eng today_rev
    today_cto=$(today_count "$AGENT")
    today_eng=$(today_count "engineer")
    today_rev=$(today_count "reviewer")

    local body="## Standup $(date '+%Y-%m-%d %H:%M')

**Activity today:**
- CTO: $today_cto actions
- Engineer: $today_eng actions
- Reviewer: $today_rev actions

**Cycles completed:** $(grep -c 'CYCLE_DONE' "$STATE_DIR/events.log" 2>/dev/null || echo 0)"

    post_discussion "$CAT_STANDUP" "📊 Standup $(date '+%Y-%m-%d')" "$body" "$AGENT_CTO" || true
    log "✅ Standup posted"
}

# ────────────────────────────────────────────
# approve-plans — Review and approve implementation plans
# ────────────────────────────────────────────
run_approve_plans() {
    # Receives: "approve <feature_id>"
    local fid="${1:-}"
    [ -z "$fid" ] && { log "No feature ID"; return 0; }

    local topic plan_file discussion
    topic=$(feature_field "$fid" "topic")
    plan_file=$(feature_field "$fid" "plan")
    discussion=$(feature_field "$fid" "discussion")

    [ ! -f "$plan_file" ] && { log "No plan file for #$fid"; return 0; }

    log "📋 Reviewing plan #$fid: $topic"

    # Read FULL plan from disk — no truncation, no API, no control chars
    local plan_body
    plan_body=$(cat "$plan_file")
    local plan_size=${#plan_body}
    log "  Plan: $plan_size chars from $plan_file"

    # Dynamic context — CTO agent definition provides system prompt
    local approve_prompt="## Plan #$fid: $topic

$plan_body

Review this plan. Start with **APPROVED** or **NEEDS WORK**."

    local response
    response=$(safe_claude "cto" "$approve_prompt") || return 1

    if echo "$response" | grep -qi "APPROVED"; then
        feature_set_status "$fid" "approved"
        [ -n "$discussion" ] && [ "$discussion" != "null" ] && \
            reply_to_discussion "$discussion" "✅ **Plan approved.** Engineer will implement." "$AGENT_CTO" 2>/dev/null || true
        log "✅ Plan #$fid approved"
    else
        # Append feedback — planner will iterate on next cycle
        local note
        note=$(echo "$response" | head -5 | tr '\n' ' ')
        feature_add_feedback "$fid" "cto" "needs-work" "$note"

        # Track CTO rejection count for planner escalation
        local reject_count
        reject_count=$(python3 -c "
import json, os
d = json.load(open(os.path.join('${_FEATURE_DIR}', '${fid}.json')))
rc = d.get('reject_count', 0) + 1
d['reject_count'] = rc
if rc >= 3 and not d.get('model'):
    d['model'] = 'opus'
    print(f'ESCALATE:{rc}')
else:
    print(f'REJECT:{rc}')
json.dump(d, open(os.path.join('${_FEATURE_DIR}', '${fid}.json'), 'w'), indent=2)
" 2>/dev/null)
        if [[ "$reject_count" == ESCALATE* ]]; then
            log "🔺 CTO rejected ${reject_count#*:} times — escalating planner to opus"
        fi

        feature_set_status "$fid" "triage"
        [ -n "$discussion" ] && [ "$discussion" != "null" ] && \
            reply_to_discussion "$discussion" "🔄 **Plan needs work.** Planner will iterate." "$AGENT_CTO" 2>/dev/null || true
        log "🔄 Plan #$fid needs work (feedback saved)"
    fi
}

# Dispatch
case "$MODE" in
    scan)        run_scan ;;
    triage)      run_triage ;;
    approve*)    run_approve_plans "${MODE#approve }" ;;
    review-prs)  run_review_prs ;;
    standup)     run_standup ;;
    *)           echo "Usage: $0 {scan|triage|approve <fid>|review-prs|standup}"; exit 1 ;;
esac
