#!/bin/bash
# ============================================================
# 📊 Dashboard — Live status display (runs in a tmux pane)
#
# Shows a continuously updating view of:
# - Agent status (which pane is active)
# - Recent GitHub Discussions activity
# - PR status
# - Token/cost estimates
#
# This is the "Sims view" — you see your agents working.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config-loader.sh"

# Parse --project flag from args
eval "$(parse_project_flag "$@")"

SESSION_NAME="agent-factory"

# ANSI colors
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'
NC='\033[0m'

draw_dashboard() {
    clear

    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║            🏭  A I   A G E N T   F A C T O R Y             ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Agent status from log files
    echo -e "${BOLD}  AGENTS${NC}"
    echo -e "  ──────"

    for agent_name in cto senior-engineer reviewer; do
        local logfile="$LOG_DIR/$agent_name.log"
        local icon status last_action elapsed_label

        case "$agent_name" in
            cto)             icon="🎯"; display_name="CTO" ;;
            senior-engineer) icon="👷"; display_name="Sr. Engineer" ;;
            reviewer)        icon="🔎"; display_name="Reviewer" ;;
        esac

        if [ -f "$logfile" ] && [ -s "$logfile" ]; then
            last_action=$(tail -1 "$logfile" 2>/dev/null | sed 's/\[.*\] \[.*\] //')

            # Check how old the last log entry is
            local last_mod
            last_mod=$(stat -f %m "$logfile" 2>/dev/null || stat -c %Y "$logfile" 2>/dev/null || echo 0)
            local now
            now=$(date +%s)
            local age=$(( now - last_mod ))

            if [ "$age" -lt 120 ]; then
                status="${GREEN}● ACTIVE${NC}"
            elif [ "$age" -lt 600 ]; then
                status="${YELLOW}◐ IDLE${NC}"
            else
                status="${DIM}○ SLEEPING${NC}"
            fi

            if [ "$age" -lt 60 ]; then
                elapsed_label="just now"
            elif [ "$age" -lt 3600 ]; then
                elapsed_label="$(( age / 60 ))m ago"
            else
                elapsed_label="$(( age / 3600 ))h ago"
            fi
        else
            status="${DIM}○ NOT STARTED${NC}"
            last_action="Waiting for first run"
            elapsed_label="-"
        fi

        printf "  ${icon} %-14s %b  ${DIM}(%s)${NC}\n" "$display_name" "$status" "$elapsed_label"
        printf "     ${DIM}%s${NC}\n" "${last_action:0:60}"
        echo ""
    done

    # Recent GitHub activity
    echo -e "${BOLD}  RECENT DISCUSSIONS${NC}"
    echo -e "  ──────────────────"

    # Try to get recent discussions (silently fail if no gh/repo)
    local recent
    recent=$(gh api graphql -f query='{
      repository(owner:"'"$GITHUB_OWNER"'", name:"'"$GITHUB_REPO"'") {
        discussions(first: 5, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes { number title category { name } comments { totalCount } updatedAt }
        }
      }
    }' 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for d in data['data']['repository']['discussions']['nodes']:
        cat = d['category']['name'][:8]
        comments = d['comments']['totalCount']
        print(f\"  #{d['number']:>3}  [{cat:<8}]  {d['title'][:45]:<45}  💬{comments}\")
except:
    pass
" 2>/dev/null)

    if [ -n "$recent" ]; then
        echo "$recent"
    else
        echo -e "  ${DIM}(no discussions yet — run ./setup.sh first)${NC}"
    fi

    echo ""

    # Open PRs
    echo -e "${BOLD}  OPEN PRs${NC}"
    echo -e "  ────────"

    local prs
    prs=$(gh pr list --repo "$GITHUB_REPO_FULL" --json number,title,state --limit 5 2>/dev/null | python3 -c "
import sys, json
try:
    for pr in json.load(sys.stdin):
        print(f\"  #{pr['number']:>3}  {pr['title'][:55]}\")
except:
    pass
" 2>/dev/null)

    if [ -n "$prs" ]; then
        echo "$prs"
    else
        echo -e "  ${DIM}(no open PRs)${NC}"
    fi

    echo ""

    # Metrics
    echo -e "${BOLD}  METRICS${NC}"
    echo -e "  ───────"

    local total_log_lines=0
    for logfile in "$LOG_DIR"/*.log; do
        if [ -f "$logfile" ]; then
            total_log_lines=$(( total_log_lines + $(wc -l < "$logfile") ))
        fi
    done

    local orchestrator_cycles=0
    if [ -f "$LOG_DIR/orchestrator.log" ]; then
        orchestrator_cycles=$(grep -c "CYCLE.*complete" "$LOG_DIR/orchestrator.log" 2>/dev/null || echo 0)
    fi

    echo "  Cycles completed:  $orchestrator_cycles"
    echo "  Total log lines:   $total_log_lines"
    echo "  Log dir size:      $(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)"
    echo ""

    echo -e "${DIM}  Last refresh: $(date '+%H:%M:%S') — refreshes every 10s${NC}"
    echo -e "${DIM}  Press Ctrl+C to exit dashboard${NC}"
}

# ────────────────────────────────────────────
# Main loop — refresh every 10s
# ────────────────────────────────────────────
trap 'echo ""; echo "Dashboard closed."; exit 0' INT TERM

while true; do
    draw_dashboard
    sleep 10
done
