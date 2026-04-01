#!/bin/bash
# ============================================================
# 🏭 factory.sh — Start/stop the agent factory
#
# Usage:
#   ./factory.sh start       Start the orchestrator in tmux
#   ./factory.sh stop        Stop gracefully
#   ./factory.sh restart     Stop + start
#   ./factory.sh attach      Attach to running session
#   ./factory.sh forum       Open GitHub Discussions in browser
#   ./factory.sh status      Show state + recent activity
#   ./factory.sh logs        Tail all logs
#   ./factory.sh kill        Force kill
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config-loader.sh"

# Parse --project and --env flags from args
eval "$(parse_project_flag "$@")"
eval "$(parse_env_flag "$@")"

source "$SCRIPT_DIR/lib/state.sh"

# Include project + env in tmux session for isolation
SESSION_NAME="agent-factory${PROJECT_NAME:+-$PROJECT_NAME}${ENV_NAME:+-$ENV_NAME}"

# ────────────────────────────────────────────
# START
# ────────────────────────────────────────────
do_start() {
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Already running. Use: ./factory.sh attach"
        exit 0
    fi

    echo "🏭 Starting Agent Factory..."
    echo "   Project: $TARGET_PROJECT"
    echo "   Env:     ${ENV_NAME:-prod}"
    echo "   Branch:  ${DEPLOY_BRANCH:-main}"
    echo "   Repo:    $GITHUB_REPO_FULL"
    echo "   Forum:   https://github.com/$GITHUB_REPO_FULL/discussions"

    # Simple 2-pane layout:
    # ┌───────────────────────────────────┐
    # │         Orchestrator              │
    # │         (main loop)               │
    # ├───────────────────────────────────┤
    # │         Control shell             │
    # │   (kick.sh, manual commands)      │
    # └───────────────────────────────────┘

    tmux new-session -d -s "$SESSION_NAME" -n "factory" -x 200 -y 50
    tmux split-window -v -t "$SESSION_NAME:factory" -l 10

    # Pane titles
    tmux set-option -t "$SESSION_NAME" pane-border-status top
    tmux set-option -t "$SESSION_NAME" pane-border-format " #{pane_title} "
    tmux select-pane -t "$SESSION_NAME:factory.0" -T "🤖 Orchestrator"
    tmux select-pane -t "$SESSION_NAME:factory.1" -T "⚡ Control"

    # Status bar
    tmux set-option -t "$SESSION_NAME" status-style "bg=colour235,fg=colour136"
    tmux set-option -t "$SESSION_NAME" status-left "#[fg=colour46,bold] 🏭 AGENT FACTORY "
    tmux set-option -t "$SESSION_NAME" status-right "#[fg=colour166] %H:%M:%S "
    tmux set-option -t "$SESSION_NAME" status-interval 5

    # Pane 0: orchestrator (pass --project and --env if set)
    local flags=""
    if [ -n "${PROJECT_NAME:-}" ]; then
        flags="--project $PROJECT_NAME"
    fi
    if [ -n "${ENV_NAME:-}" ]; then
        flags="$flags --env $ENV_NAME"
    fi
    tmux send-keys -t "$SESSION_NAME:factory.0" \
        "cd '$SCRIPT_DIR' && ./orchestrator.sh $flags 2>&1 | tee -a '$LOG_DIR/orchestrator.log'" Enter

    # Pane 1: control shell
    tmux send-keys -t "$SESSION_NAME:factory.1" \
        "cd '$SCRIPT_DIR' && echo '⚡ Control — kick.sh commands, or ./factory.sh forum to open Discussions'" Enter

    tmux select-pane -t "$SESSION_NAME:factory.1"

    echo ""
    echo "✅ Factory started in tmux."
    echo ""
    echo "  ./factory.sh attach    Attach to session"
    echo "  ./factory.sh forum     Open Discussions in browser"
    echo "  ./factory.sh logs      Tail logs"
    echo ""
    echo "Inside tmux:"
    echo "  Ctrl+B ↑↓     Switch panes"
    echo "  Ctrl+B z       Zoom pane"
    echo "  Ctrl+B d       Detach (keeps running)"
    echo ""

    if [ -t 0 ]; then
        read -p "Attach now? [Y/n] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            tmux attach -t "$SESSION_NAME"
        fi
    fi
}

# ────────────────────────────────────────────
# STOP
# ────────────────────────────────────────────
do_stop() {
    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Not running."
        return
    fi
    echo "🛑 Stopping..."
    # Send Ctrl+C to orchestrator pane
    tmux send-keys -t "$SESSION_NAME:factory.0" C-c 2>/dev/null || true
    sleep 3
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    echo "✅ Stopped."
}

# ────────────────────────────────────────────
# FORUM — Open GitHub Discussions
# ────────────────────────────────────────────
do_forum() {
    local url="https://github.com/$GITHUB_REPO_FULL/discussions"
    echo "🌐 Opening: $url"
    open "$url" 2>/dev/null || xdg-open "$url" 2>/dev/null || echo "Open manually: $url"
}

# ────────────────────────────────────────────
# STATUS
# ────────────────────────────────────────────
do_status() {
    echo "🏭 Agent Factory Status"
    echo "═══════════════════════"

    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Session:  ✅ RUNNING"
    else
        echo "Session:  ⏹️  STOPPED"
    fi

    echo "Forum:    https://github.com/$GITHUB_REPO_FULL/discussions"
    echo ""

    # State stats
    if [ -f "$STATE_DIR/processed.log" ]; then
        local total today_total
        total=$(wc -l < "$STATE_DIR/processed.log" | tr -d ' ')
        today_total=$(grep "^$(date -u '+%Y-%m-%d')" "$STATE_DIR/processed.log" 2>/dev/null | wc -l | tr -d ' ')
        echo "Processed: $total total, $today_total today"
    else
        echo "Processed: 0 (no state yet)"
    fi

    if [ -f "$STATE_DIR/events.log" ]; then
        local cycles errors
        cycles=$(grep -c 'CYCLE_DONE' "$STATE_DIR/events.log" 2>/dev/null || echo 0)
        errors=$(grep -c 'ERROR\|FAILED\|TIMEOUT' "$STATE_DIR/events.log" 2>/dev/null || echo 0)
        echo "Cycles:    $cycles completed"
        echo "Errors:    $errors total"
    fi

    echo ""
    echo "Recent events:"
    if [ -f "$STATE_DIR/events.log" ]; then
        tail -10 "$STATE_DIR/events.log" | while IFS='|' read -r ts agent event msg; do
            printf "  %-20s %-12s %-15s %s\n" "$ts" "$agent" "$event" "$msg"
        done
    else
        echo "  (none yet)"
    fi

    echo ""
    echo "Locks (global claude pool + local):"
    local has_locks=false
    for lock_search_dir in "$GLOBAL_LOCK_DIR" "$LOCK_DIR"; do
        for lockfile in "$lock_search_dir"/*.lock; do
            [ -e "$lockfile" ] || continue
            if [ -f "$lockfile" ]; then
                local lock_name age
                lock_name=$(basename "$lockfile" .lock)
                local lock_time now
                lock_time=$(cat "$lockfile")
                now=$(date +%s)
                age=$(( now - lock_time ))
                echo "  ⚠️  $lock_name — held for ${age}s"
                has_locks=true
            fi
        done
    done
    if [ "$has_locks" = false ]; then
        echo "  (none — all clear)"
    fi
}

# ────────────────────────────────────────────
# LOGS
# ────────────────────────────────────────────
do_logs() {
    mkdir -p "$LOG_DIR"
    for f in orchestrator product-manager cto planner senior-engineer test-runner reviewer security compound self-improve devops sre quality-gate docs-writer dependency-auditor accessibility-auditor qa-writer release-manager; do
        touch "$LOG_DIR/$f.log"
    done
    tail -f "$LOG_DIR"/*.log
}

# ────────────────────────────────────────────
# KILL
# ────────────────────────────────────────────
do_kill() {
    echo "⚠️  Force killing..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    pkill -f "claude -p" 2>/dev/null || true
    # Clean stale locks (per-project + global pool)
    rm -f "$LOCK_DIR"/*.lock 2>/dev/null || true
    rm -f "$GLOBAL_LOCK_DIR"/claude-*.lock 2>/dev/null || true
    rm -rf "$GLOBAL_LOCK_DIR"/claude-*.d 2>/dev/null || true
    echo "Done."
}

# ────────────────────────────────────────────
case "${1:-help}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 2; do_start ;;
    attach)  tmux attach -t "$SESSION_NAME" 2>/dev/null || echo "Not running. ./factory.sh start" ;;
    forum)   do_forum ;;
    status)  do_status ;;
    logs)    do_logs ;;
    kill)    do_kill ;;
    help|*)
        echo "🏭 Agent Factory"
        echo ""
        echo "  ./factory.sh start     Start orchestrator in tmux"
        echo "  ./factory.sh stop      Graceful stop"
        echo "  ./factory.sh restart   Restart"
        echo "  ./factory.sh attach    Attach to tmux session"
        echo "  ./factory.sh forum     Open GitHub Discussions in browser"
        echo "  ./factory.sh status    Show state, locks, errors"
        echo "  ./factory.sh logs      Tail all agent logs"
        echo "  ./factory.sh kill      Force kill + clear locks"
        ;;
esac
