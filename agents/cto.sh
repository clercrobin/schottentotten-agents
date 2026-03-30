#!/bin/bash
# ============================================================
# 🎯 CTO Agent — robust version (bash 3.2 compatible)
# ============================================================
set -uo pipefail
# NOTE: no set -e — we handle errors explicitly

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-scan}"
AGENT="cto"

log() { echo "[$(date '+%H:%M:%S')] [CTO] $*"; }

# ────────────────────────────────────────────
# scan — Find issues in codebase, post to Triage
# ────────────────────────────────────────────
run_scan() {
    log "🔍 Scanning codebase..."
    log "  target: ${TARGET_PROJECT:-.}"

    local prompt_text
    prompt_text=$(load_prompt "cto-scan") || { log "Cannot load cto-scan prompt"; return 1; }

    local scan_result
    scan_result=$(safe_claude "$AGENT" "$prompt_text" \
    --allowedTools "Bash,Read,Glob,Grep") || {
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

    local posted=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue

        local title body
        title=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
        body=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])")

        log "📤 Posting issue: $title"
        local disc_num
        disc_num=$(post_discussion "$CAT_TRIAGE" "$title" "$body" "$AGENT_CTO") || {
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

        local triage_prompt
        triage_prompt=$(load_prompt "cto-triage") || continue
        triage_prompt=$(render_prompt "$triage_prompt" \
            DISC_NUM "$num" \
            TITLE "$title" \
            BODY "$body")

        local response
        response=$(safe_claude "$AGENT" "$triage_prompt" \
        --allowedTools "Read,Glob,Grep") || continue

        reply_to_discussion "$num" "$response" "$AGENT_CTO" || continue
        mark_processed "$num" "$AGENT" "triaged"
        log "✅ Triaged #$num"
    done
}

# ────────────────────────────────────────────
# review-prs — Merge approved PRs
# ────────────────────────────────────────────
run_review_prs() {
    log "🔀 Checking for mergeable PRs..."

    local reviews
    reviews=$(get_discussions "$CAT_CODE_REVIEW" 10) || return 0

    echo "$reviews" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    comments = ' '.join(d.get('last_comments', []))
    if 'APPROVED' in comments.upper() or 'LGTM' in comments.upper():
        title = d['title'].replace('\t', ' ')
        print(f\"{d['number']}\t{title}\")
" 2>/dev/null | while IFS=$'\t' read -r num title; do
        [ -z "$num" ] && continue

        is_processed "$num" "$AGENT" "merged" && continue

        log "🟢 Approving #$num: $title"
        reply_to_discussion "$num" "✅ **Merge approved.** Reviewed and shipping." "$AGENT_CTO" || continue
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

# Dispatch
case "$MODE" in
    scan)       run_scan ;;
    triage)     run_triage ;;
    review-prs) run_review_prs ;;
    standup)    run_standup ;;
    *)          echo "Usage: $0 {scan|triage|review-prs|standup}"; exit 1 ;;
esac
