#!/bin/bash
# ============================================================
# 🔄 Compound Agent — Compound Engineering: Compound phase
#
# After work is merged, this agent extracts learnings:
# - Documents what worked and what didn't
# - Saves reusable solutions to docs/solutions/
# - Suggests CLAUDE.md updates for the target project
# - Creates searchable knowledge for future cycles
#
# "Each cycle teaches systems better approaches."
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_AGENT_MODE="${1:-}"
set --
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${_AGENT_MODE:-extract}"
AGENT="compound"

log() { echo "[$(date '+%H:%M:%S')] [COMP] $*"; }

# ────────────────────────────────────────────
# extract — Find merged work and document solutions
# ────────────────────────────────────────────
run_extract() {
    log "🔄 Looking for merged work to compound..."

    # Look for discussions tagged as "merged" in Code Review
    local reviews
    reviews=$(get_discussions "$CAT_CODE_REVIEW" 20) || return 0

    echo "$reviews" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    comments = ' '.join(d.get('last_comments', []))
    if 'merged' in comments.lower() or 'merge approved' in comments.lower():
        title = d['title'].replace('\t', ' ')
        body = d['body'][:3000].replace('\t', ' ')
        print(f\"{d['number']}\t{title}\t{body}\")
" 2>/dev/null | while IFS=$'\t' read -r num title body; do
        [ -z "$num" ] && continue

        is_processed "$num" "$AGENT" "compounded" && continue

        log "🔄 Compounding #$num: $title"

        # Get the full discussion thread for context
        local thread_comments
        thread_comments=$(echo "$reviews" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    if d['number'] == $num:
        print('\n---\n'.join(d.get('last_comments', [])))
        break
" 2>/dev/null)

        # Extract branch name to get the diff
        local branch_name diff_content=""
        branch_name=$(echo "$body" | sed -n 's/.*Branch:[[:space:]]*`\([^`]*\)`.*/\1/p' | head -1)

        if [ -n "$branch_name" ]; then
            cd "$TARGET_PROJECT"
            git fetch origin 2>/dev/null || true
            local base_branch
            base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || echo "main")
            diff_content=$(git diff "$base_branch"..."origin/$branch_name" 2>/dev/null | head -c 6000 || echo "(could not get diff)")
        fi

        local compound_prompt
        compound_prompt=$(load_prompt "compound-extract") || continue
        compound_prompt=$(render_prompt "$compound_prompt" \
            TITLE "$title" \
            BODY "$body" \
            THREAD "$thread_comments" \
            DIFF_CONTENT "$diff_content")

        local result
        result=$(safe_claude "$AGENT" "$compound_prompt" \
        --allowedTools "Bash,Read,Write,Edit,Glob,Grep") || continue

        # Post the compound summary
        post_discussion "$CAT_ENGINEERING" "🔄 Compound: $title" \
"**Source:** Code Review #$num

$result

---
*Compound Engineering — knowledge extracted for future cycles.*" "$AGENT_COMPOUND" || true

        mark_processed "$num" "$AGENT" "compounded"
        log "✅ Compounded #$num"
    done
}

case "$MODE" in
    extract) run_extract ;;
    *)       echo "Usage: $0 {extract}"; exit 1 ;;
esac
