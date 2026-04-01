#!/bin/bash
# ============================================================
# 🧪 QA Writer Agent — Test generation
#
# Analyzes code changes and generates missing tests.
# Runs AFTER the test-runner identifies gaps, and AFTER
# the reviewer flags insufficient test coverage.
#
# "The test-runner executes tests. The QA writer creates them."
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_AGENT_MODE="${1:-}"
set --
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${_AGENT_MODE:-generate}"
AGENT="qa-writer"

log() { echo "[$(date '+%H:%M:%S')] [QA] $*"; }

# ────────────────────────────────────────────
# generate — Write tests for code that lacks coverage
# ────────────────────────────────────────────
run_generate() {
    log "🧪 Looking for PRs needing tests..."

    local reviews
    reviews=$(get_discussions "$CAT_CODE_REVIEW" 15) || return 0

    # Find reviews that mention insufficient tests or no tests detected
    echo "$reviews" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    comments = ' '.join(d.get('last_comments', []))
    needs_tests = (
        'NO TESTS DETECTED' in comments.upper() or
        'test coverage' in comments.lower() or
        'missing test' in comments.lower() or
        'add test' in comments.lower() or
        'tests-failing' in comments.lower()
    )
    if needs_tests:
        title = d['title'].replace('\t', ' ')
        body = d['body'][:2000].replace('\t', ' ')
        print(f\"{d['number']}\t{title}\t{body}\")
" 2>/dev/null | while IFS=$'\t' read -r num title body; do
        [ -z "$num" ] && continue

        is_processed "$num" "$AGENT" "tests-written" && continue

        log "🧪 Writing tests for #$num: $title"

        # Extract branch and checkout
        local branch_name
        branch_name=$(echo "$body" | sed -n 's/.*Branch:[[:space:]]*`\([^`]*\)`.*/\1/p' | head -1)

        if [ -z "$branch_name" ]; then
            log "  ⚠️  No branch found — skipping"
            mark_processed "$num" "$AGENT" "tests-written"
            continue
        fi

        cd "$TARGET_PROJECT"
        git fetch origin 2>/dev/null || true
        git checkout "$branch_name" 2>/dev/null || {
            log "  ⚠️  Cannot checkout $branch_name"
            continue
        }

        # Get diff to understand what changed
        local base_branch
        base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || echo "main")
        local diff_content
        diff_content=$(git diff "$base_branch"..."$branch_name" 2>/dev/null | head -c 6000)

        local qa_prompt
        qa_prompt=$(load_prompt "qa-generate") || continue
        qa_prompt=$(render_prompt "$qa_prompt" \
            TITLE "$title" \
            DIFF_CONTENT "$diff_content")

        local result
        result=$(safe_claude "$AGENT" "$qa_prompt" \
        --allowedTools "Bash,Read,Write,Edit,Glob,Grep") || {
            git checkout "$base_branch" 2>/dev/null || true
            continue
        }

        # Commit test files
        cd "$TARGET_PROJECT"
        if ! git diff --cached --quiet || ! git diff --quiet; then
            git add -A
            git commit -m "test: add tests for #$num" \
                -m "Co-Authored-By: AI QA Writer <agent@factory>" || true
            git push || true
            reply_to_discussion "$num" "🧪 **Tests added.** Generated test coverage for the changes in this PR.

$result" "$AGENT_QA_WRITER" || true
            log "✅ Tests written and pushed for #$num"
        else
            log "  📝 No new tests needed for #$num"
        fi

        git checkout "$base_branch" 2>/dev/null || true
        mark_processed "$num" "$AGENT" "tests-written"
    done
}

case "$MODE" in
    generate) run_generate ;;
    *)        echo "Usage: $0 {generate}"; exit 1 ;;
esac
