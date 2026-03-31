#!/bin/bash
# ============================================================
# 📝 Docs Writer Agent — Documentation maintenance
#
# Detects doc drift, updates README, generates API docs,
# maintains changelogs, and keeps docs in sync with code.
#
# "Documentation that drifts from code is worse than no docs."
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_AGENT_MODE="${1:-}"
set --
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${_AGENT_MODE:-audit}"
AGENT="docs-writer"

log() { echo "[$(date '+%H:%M:%S')] [DOCS] $*"; }

# ────────────────────────────────────────────
# audit — Check for doc drift and missing docs
# ────────────────────────────────────────────
run_audit() {
    log "📝 Auditing documentation..."

    local prompt_text
    prompt_text=$(load_prompt "docs-audit") || { log "Cannot load docs-audit prompt"; return 1; }

    local audit_result
    audit_result=$(safe_claude "$AGENT" "$prompt_text" \
    --allowedTools "Read,Glob,Grep") || {
        log "⚠️  Doc audit failed"
        return 1
    }

    local result_len=${#audit_result}
    if [ "$result_len" -lt 20 ]; then
        log "📝 Docs look good — no issues found"
        return 0
    fi

    # Parse issues and post to Triage
    local issue_count
    issue_count=$(echo "$audit_result" | python3 -c "
import sys, json
text = sys.stdin.read()
try:
    start = text.index('[')
    end = text.rindex(']') + 1
    issues = json.loads(text[start:end])
    print(len(issues))
except (ValueError, json.JSONDecodeError):
    print(0)
" 2>/dev/null)

    log "📝 Found ${issue_count} doc issues"

    echo "$audit_result" | python3 -c "
import sys, json
text = sys.stdin.read()
try:
    start = text.index('[')
    end = text.rindex(']') + 1
    issues = json.loads(text[start:end])
except (ValueError, json.JSONDecodeError):
    sys.exit(0)
for issue in issues[:3]:
    print(json.dumps(issue))
" 2>/dev/null | while IFS= read -r line; do
        [ -z "$line" ] && continue
        local title body
        title=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'[DOCS] {d[\"title\"]}')")
        body=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'**Category:** documentation\n**Files:** {\", \".join(d.get(\"files\",[]))}\n\n{d[\"description\"]}\n\n**Suggested approach:** {d[\"suggested_approach\"]}')")

        post_discussion "$CAT_TRIAGE" "$title" "$body" "$AGENT_DOCS" || continue
        log "📤 Posted doc issue: $title"
    done
}

# ────────────────────────────────────────────
# update — Fix doc issues (runs after engineer implements)
# ────────────────────────────────────────────
run_update() {
    log "📝 Checking for merged PRs needing doc updates..."

    local reviews
    reviews=$(get_discussions "$CAT_CODE_REVIEW" 10) || return 0

    echo "$reviews" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    comments = ' '.join(d.get('last_comments', []))
    if 'merged' in comments.lower() or 'merge approved' in comments.lower():
        title = d['title'].replace('\t', ' ')
        body = d['body'][:2000].replace('\t', ' ')
        print(f\"{d['number']}\t{title}\t{body}\")
" 2>/dev/null | while IFS=$'\t' read -r num title body; do
        [ -z "$num" ] && continue
        is_processed "$num" "$AGENT" "docs-updated" && continue

        log "📝 Checking doc needs for #$num"

        local update_prompt
        update_prompt=$(load_prompt "docs-update") || continue
        update_prompt=$(render_prompt "$update_prompt" \
            TITLE "$title" \
            BODY "$body")

        local result
        result=$(safe_claude "$AGENT" "$update_prompt" \
        --allowedTools "Bash,Read,Write,Edit,Glob,Grep") || continue

        if echo "$result" | grep -qi "NO_UPDATES_NEEDED"; then
            log "  📝 No doc updates needed for #$num"
        else
            # Commit doc changes
            cd "$TARGET_PROJECT"
            if ! git diff --cached --quiet || ! git diff --quiet; then
                local base_branch
                base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || echo "main")
                git add -A
                git commit -m "docs: update documentation for #$num" \
                    -m "Co-Authored-By: AI Docs Writer <agent@factory>" || true
                git push || true
                log "  📝 Doc updates committed for #$num"
            fi
        fi

        mark_processed "$num" "$AGENT" "docs-updated"
    done
}

case "$MODE" in
    audit)  run_audit ;;
    update) run_update ;;
    *)      echo "Usage: $0 {audit|update}"; exit 1 ;;
esac
