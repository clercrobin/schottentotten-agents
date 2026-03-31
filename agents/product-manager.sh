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

    # Source 2: Ideas discussions on agents repo (human posts feature ideas)
    # NOTE: don't use get_discussions — it filters by env tag, but human Ideas don't have tags
    local ideas ideas_count
    ideas=$(gh api graphql -F owner="$GITHUB_OWNER" -F repo="$GITHUB_REPO" -f query='
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        discussions(first: 10, states: OPEN, orderBy: {field: CREATED_AT, direction: DESC}) {
          nodes { number title body category { name } }
        }
      }
    }' --jq '[.data.repository.discussions.nodes[] | select(.category.name == "Ideas") | select(.title | test("Plan:") | not)]' 2>/dev/null || echo "[]")
    # Filter out already-processed Ideas
    ideas=$(printf '%s' "$ideas" | python3 -c "
import sys, json
ideas = json.loads(sys.stdin.read())
# Read processed log to skip already-handled Ideas
processed = set()
try:
    with open('${STATE_DIR:-state}/processed.log') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) >= 4 and parts[2] == 'product-manager' and parts[3] == 'idea-processed':
                processed.add(parts[1])
except: pass
filtered = [i for i in ideas if str(i['number']) not in processed]
print(json.dumps(filtered))
" 2>/dev/null || echo "$ideas")
    ideas_count=$(printf '%s' "$ideas" | python3 -c "import sys,json; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "0")
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

    # Process each Idea individually — reply to the Idea, update its title
    # The Idea discussion IS the feature thread. No new discussions created.
    if [ "$ideas_count" != "0" ]; then
        printf '%s' "$ideas" | python3 -c "
import sys, json
for d in json.loads(sys.stdin.read()):
    print(f\"{d['number']}\t{d['title']}\t{(d.get('body') or '')[:500]}\")
" 2>/dev/null | while IFS=$'\t' read -r idea_num idea_title idea_body; do
            [ -z "$idea_num" ] && continue

            log "  Processing Idea #$idea_num: $idea_title"

            local pm_prompt
            pm_prompt=$(load_prompt "pm-intake") || continue
            pm_prompt=$(render_prompt "$pm_prompt" \
                INTAKE_CONTEXT "### Idea #$idea_num: $idea_title\n$idea_body")

            local result
            result=$(safe_claude "$AGENT" "$pm_prompt" \
            --allowedTools "Read,Glob,Grep") || continue

            # Reply to the original Idea with the PM analysis
            reply_to_discussion "$idea_num" "## Product Manager Analysis

$result" "$AGENT_PM" || true

            # Move the Idea to Triage category by updating its title
            # (we can't change category via API, so we update the title to include [TRIAGE])
            local topic
            topic=$(echo "$idea_title" | sed 's/^\[.*\] *//')
            advance_status "$idea_num" "TRIAGE" "$topic" "PM analysis complete. Ready for planning." "$AGENT_PM" 2>/dev/null || true

            mark_processed "$idea_num" "$AGENT" "idea-processed"
            log "  ✅ Idea #$idea_num → [TRIAGE] $topic"
        done
    fi

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
