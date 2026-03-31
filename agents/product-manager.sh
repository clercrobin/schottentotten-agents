#!/bin/bash
# ============================================================
# 📊 Product Manager Agent — Feature direction & human gate
#
# Decides WHAT to build by:
# 1. Reading feature requests from the human (backlog/ dir + Ideas discussions)
# 2. Reading GitHub issues on the target project
# 3. Synthesizing into prioritized specs
# 4. Escalating to the human when uncertain (via Q&A discussions)
#
# The human is the product owner. This agent translates intent
# into actionable specs, but never decides strategy alone.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-intake}"
AGENT="product-manager"

log() { echo "[$(date '+%H:%M:%S')] [PM] $*"; }

# ────────────────────────────────────────────
# intake — Collect feature requests from all sources
# ────────────────────────────────────────────
run_intake() {
    log "📊 Collecting feature requests..."

    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"

    # Source 1: GitHub Issues on the target project
    local issues
    issues=$(gh issue list --repo "$target_repo" --state open --json number,title,body,labels --limit 10 2>/dev/null || echo "[]")
    local issue_count
    issue_count=$(echo "$issues" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    log "  GitHub issues: $issue_count open"

    # Source 2: Ideas discussions on agents repo (human posts feature ideas here)
    local ideas
    ideas=$(get_discussions "Ideas" 10 2>/dev/null || echo "[]")
    local ideas_count
    ideas_count=$(echo "$ideas" | python3 -c "import sys,json; print(len([d for d in json.load(sys.stdin) if 'Plan:' not in d.get('title','')]))" 2>/dev/null || echo "0")
    log "  Ideas discussions: $ideas_count"

    if [ "$issue_count" = "0" ] && [ "$ideas_count" = "0" ]; then
        log "  No new inputs"
        return 0
    fi

    # Build intake context for Claude
    local intake_context="## Sources\n"

    # GitHub issues
    if [ "$issue_count" != "0" ]; then
        local issues_text
        issues_text=$(echo "$issues" | python3 -c "
import sys, json
for i in json.load(sys.stdin)[:5]:
    labels = ', '.join(l['name'] for l in i.get('labels', []))
    body = i['body'][:200] if i.get('body') else '(no body)'
    print(f\"### Issue #{i['number']}: {i['title']}\n**Labels:** {labels}\n{body}\n\")
" 2>/dev/null)
        intake_context="$intake_context\n### GitHub Issues\n$issues_text"
    fi

    # Ideas discussions
    if [ "$ideas_count" != "0" ]; then
        local ideas_text
        ideas_text=$(echo "$ideas" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    if 'Plan:' in d.get('title', ''):
        continue
    body = d['body'][:300] if d.get('body') else '(no body)'
    print(f\"### Idea #{d['number']}: {d['title']}\n{body}\n\")
" 2>/dev/null)
        intake_context="$intake_context\n### Ideas Discussions\n$ideas_text"
    fi

    # Ask Claude to prioritize and spec
    local pm_prompt
    pm_prompt=$(load_prompt "pm-intake") || { log "Cannot load pm-intake prompt"; return 1; }
    pm_prompt=$(render_prompt "$pm_prompt" \
        INTAKE_CONTEXT "$intake_context")

    local result
    result=$(safe_claude "$AGENT" "$pm_prompt" \
    --allowedTools "Read,Glob,Grep") || {
        log "⚠️  PM intake failed"
        return 1
    }

    # Parse result — create Triage items for clear features, Q&A for unclear ones
    echo "$result" | python3 -c "
import sys, json

text = sys.stdin.read()
# Look for TRIAGE and ESCALATE sections
triage_items = []
escalate_items = []
current = None
for line in text.split('\n'):
    if '## TRIAGE' in line.upper() or '## READY' in line.upper():
        current = 'triage'
    elif '## ESCALATE' in line.upper() or '## ASK' in line.upper():
        current = 'escalate'
    elif line.strip().startswith('###') and current:
        title = line.strip('# ').strip()
        if current == 'triage':
            triage_items.append(title)
        elif current == 'escalate':
            escalate_items.append(title)

for item in triage_items:
    print(f'TRIAGE\t{item}')
for item in escalate_items:
    print(f'ESCALATE\t{item}')
" 2>/dev/null | while IFS=$'\t' read -r action title; do
        [ -z "$action" ] && continue

        if [ "$action" = "TRIAGE" ]; then
            post_discussion "$CAT_TRIAGE" "[FEATURE] $title" \
"**Source:** Product Manager intake

$result" "$AGENT_PM" || true
            log "📤 Created triage: $title"
        elif [ "$action" = "ESCALATE" ]; then
            post_discussion "$CAT_DECISIONS" "❓ Decision needed: $title" \
"**@${GITHUB_OWNER} — Product Manager needs your input.**

$result

---
*⏸️ Agents are paused on this item until you reply. All other work continues.*" "$AGENT_PM" || true
            log "❓ Escalated to human: $title"
        fi
    done

    log "✅ Intake complete"
}

# ────────────────────────────────────────────
# check-decisions — Look for human responses to escalated questions
# ────────────────────────────────────────────
run_check_decisions() {
    log "📊 Checking for human decisions..."

    local qa_discussions
    qa_discussions=$(get_discussions "Q&A" 20 2>/dev/null || echo "[]")

    # Handle prod approval ("approve" reply to "Ready for prod" Q&A)
    printf '%s' "$qa_discussions" | python3 -c "
import sys, json, re
raw = sys.stdin.read()
raw = raw.translate({i: None for i in range(32) if i not in (9, 10, 13)})
try:
    for d in json.loads(raw):
        if 'Ready for prod' not in d.get('title', ''):
            continue
        comments = d.get('last_comments', [])
        human_replies = [c for c in comments if 'Agent' not in c[:20]]
        for reply in human_replies:
            if 'approve' in reply.lower():
                print(f\"{d['number']}\tapprove\")
                break
except: pass
" 2>/dev/null | while IFS=$'\t' read -r num action; do
        [ -z "$num" ] && continue
        is_processed "$num" "$AGENT" "prod-actioned" && continue

        if [ "$action" = "approve" ]; then
            log "🚀 Human approved prod release from Q&A #$num — merging staging → main"

            local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
            local staging_branch="${DEPLOY_BRANCH:-staging}"

            cd "$TARGET_PROJECT"
            git fetch origin 2>/dev/null || true
            git checkout main 2>/dev/null || true
            git pull origin main 2>/dev/null || true
            git merge "origin/$staging_branch" --no-edit -m "release: merge staging to prod (approved in Q&A #$num)" 2>&1 | tail -5

            if [ $? -eq 0 ] || git diff --quiet HEAD "origin/$staging_branch" 2>/dev/null; then
                git push origin main 2>&1 | tail -3
                reply_to_discussion "$num" "✅ **Shipped to prod.** Staging merged to main. CI deploying now." "$AGENT_PM" || true
                log "✅ Merged staging → main"
            else
                # Conflict — ask engineer to resolve
                git merge --abort 2>/dev/null || true
                reply_to_discussion "$num" "⚠️ **Merge conflict.** Staging → main has conflicts. Creating fix task." "$AGENT_PM" || true
                create_triage "Merge conflict: staging → main" \
"**Priority:** critical
Staging was approved for prod but has merge conflicts with main.
Resolve conflicts and merge manually." "$AGENT_PM" || true
                log "⚠️ Merge conflict — fix task created"
            fi

            git checkout "$staging_branch" 2>/dev/null || true
            mark_processed "$num" "$AGENT" "prod-actioned"
        fi
    done

    # Handle feature decisions ("Decision needed" Q&A)
    printf '%s' "$qa_discussions" | python3 -c "
import sys, json
raw = sys.stdin.read()
raw = raw.translate({i: None for i in range(32) if i not in (9, 10, 13)})
try:
    for d in json.loads(raw):
        if 'Decision needed' not in d.get('title', ''):
            continue
        comments = d.get('last_comments', [])
        human_replies = [c for c in comments if 'Agent' not in c[:20]]
        if human_replies:
            title = d['title'].replace('\t', ' ')
            last_reply = human_replies[-1][:500].replace('\t', ' ')
            print(f\"{d['number']}\t{title}\t{last_reply}\")
except: pass
" 2>/dev/null | while IFS=$'\t' read -r num title reply; do
        [ -z "$num" ] && continue
        is_processed "$num" "$AGENT" "decision-actioned" && continue

        log "📊 Human decision on #$num: $title"

        local decision_prompt
        decision_prompt=$(load_prompt "pm-decision") || continue
        decision_prompt=$(render_prompt "$decision_prompt" \
            TITLE "$title" \
            DECISION "$reply")

        local result
        result=$(safe_claude "$AGENT" "$decision_prompt" \
        --allowedTools "Read,Glob,Grep") || continue

        post_discussion "$CAT_TRIAGE" "[FEATURE] $(echo "$title" | sed 's/❓ Decision needed: //')" \
"**Human decision:** $reply

$result" "$AGENT_PM" || true

        reply_to_discussion "$num" "✅ **Decision received.** Created triage item for implementation." "$AGENT_PM" || true
        mark_processed "$num" "$AGENT" "decision-actioned"
        log "✅ Actioned decision #$num"
    done
}

case "$MODE" in
    intake)          run_intake ;;
    check-decisions) run_check_decisions ;;
    *)               echo "Usage: $0 {intake|check-decisions}"; exit 1 ;;
esac
