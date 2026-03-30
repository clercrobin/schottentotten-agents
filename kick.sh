#!/bin/bash
# ============================================================
# ⚡ Kick — Manually trigger a specific agent action
#
# Usage:
#   ./kick.sh cto scan          # CTO scans codebase
#   ./kick.sh cto triage        # CTO triages discussions
#   ./kick.sh cto standup       # CTO posts standup
#   ./kick.sh engineer work     # Engineer picks up a task
#   ./kick.sh engineer respond  # Engineer responds to reviews
#   ./kick.sh reviewer review   # Reviewer reviews PRs
#   ./kick.sh seed "message"    # Manually post a task to Triage
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config-loader.sh"

# Parse --project flag from args
eval "$(parse_project_flag "$@")"

source "$SCRIPT_DIR/lib/discussions.sh"

ACTION="${1:-help}"
ARG="${2:-}"

case "$ACTION" in
    cto)
        bash "$SCRIPT_DIR/agents/cto.sh" "${ARG:-scan}"
        ;;
    engineer)
        case "$ARG" in
            respond) bash "$SCRIPT_DIR/agents/senior-engineer.sh" "respond-reviews" ;;
            *)       bash "$SCRIPT_DIR/agents/senior-engineer.sh" "work" ;;
        esac
        ;;
    reviewer)
        bash "$SCRIPT_DIR/agents/reviewer.sh" "review"
        ;;
    seed)
        # Manually inject a task into the Triage channel
        if [ -z "$ARG" ]; then
            echo "Usage: ./kick.sh seed \"Your task description here\""
            exit 1
        fi
        DISC_NUM=$(post_discussion "$CAT_TRIAGE" "📌 Manual Task: $ARG" \
"## Manual Task

$ARG

---
*Manually submitted. Awaiting pickup by Senior Engineer.*" "🧑‍💻 Human")
        echo "✅ Posted task as Discussion #$DISC_NUM"
        echo "   View: https://github.com/$GITHUB_REPO_FULL/discussions/$DISC_NUM"
        ;;
    status)
        echo "🏭 AI Agent Factory — Status"
        echo ""
        echo "📋 Recent Triage:"
        get_discussions "$CAT_TRIAGE" 3 | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    print(f\"  #{d['number']}: {d['title']} ({d['comment_count']} comments)\")
" 2>/dev/null || echo "  (none)"
        echo ""
        echo "💬 Recent Engineering:"
        get_discussions "$CAT_ENGINEERING" 3 | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    print(f\"  #{d['number']}: {d['title']} ({d['comment_count']} comments)\")
" 2>/dev/null || echo "  (none)"
        echo ""
        echo "🔍 Recent Code Reviews:"
        get_discussions "$CAT_CODE_REVIEW" 3 | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    print(f\"  #{d['number']}: {d['title']} ({d['comment_count']} comments)\")
" 2>/dev/null || echo "  (none)"
        ;;
    help|*)
        echo "⚡ Kick — Manual agent trigger"
        echo ""
        echo "Usage:"
        echo "  ./kick.sh cto scan          CTO scans codebase for issues"
        echo "  ./kick.sh cto triage        CTO triages engineering discussions"
        echo "  ./kick.sh cto review-prs    CTO reviews PRs ready to merge"
        echo "  ./kick.sh cto standup       CTO posts daily standup"
        echo "  ./kick.sh engineer work     Engineer picks up next task"
        echo "  ./kick.sh engineer respond  Engineer responds to review feedback"
        echo "  ./kick.sh reviewer review   Reviewer reviews pending PRs"
        echo "  ./kick.sh seed \"message\"    Manually inject a task"
        echo "  ./kick.sh status            Show recent activity"
        ;;
esac
