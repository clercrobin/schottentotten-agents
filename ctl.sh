#!/bin/bash
# ============================================================
# 🏭 ctl.sh — Agent Factory service control (like systemctl)
#
# Usage:
#   ./ctl.sh status      Is it running? PID, uptime, errors
#   ./ctl.sh start       Start the service
#   ./ctl.sh stop        Stop the service
#   ./ctl.sh restart     Stop + start
#   ./ctl.sh logs        Tail all logs (stdout + stderr + agents)
#   ./ctl.sh errors      Show only errors from event log
#   ./ctl.sh forum       Open GitHub Discussions
#   ./ctl.sh kick        Pass-through to kick.sh
#   ./ctl.sh uninstall   Remove the launchd service
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config-loader.sh"

# Parse --project flag from args
eval "$(parse_project_flag "$@")"

source "$SCRIPT_DIR/lib/state.sh"

SERVICE_LABEL="com.agentfactory.orchestrator"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"

# ────────────────────────────────────────────
# STATUS
# ────────────────────────────────────────────
do_status() {
    echo "🏭 Agent Factory"
    echo "═══════════════════"

    # Check if launchd knows about it
    local launchd_info
    launchd_info=$(launchctl list "$SERVICE_LABEL" 2>/dev/null) || {
        echo "State:    ⏹️  NOT INSTALLED"
        echo ""
        echo "Run ./install.sh to install as a launchd service."
        return
    }

    local pid exit_code
    pid=$(echo "$launchd_info" | awk 'NR>1 {print $1}')
    exit_code=$(echo "$launchd_info" | awk 'NR>1 {print $2}')

    if [ "$pid" != "-" ] && [ -n "$pid" ] && [ "$pid" != "0" ]; then
        echo "State:    ✅ RUNNING (PID $pid)"

        # Get uptime from process
        local start_time
        start_time=$(ps -p "$pid" -o lstart= 2>/dev/null || echo "unknown")
        echo "Started:  $start_time"
    else
        echo "State:    ⏹️  STOPPED"
        if [ "$exit_code" != "0" ] && [ "$exit_code" != "-" ]; then
            echo "Last exit: $exit_code"
        fi
    fi

    echo "Forum:    https://github.com/$GITHUB_REPO_FULL/discussions"
    echo "Plist:    $PLIST_PATH"
    echo ""

    # State stats
    if [ -f "$STATE_DIR/processed.log" ]; then
        local total today_total
        total=$(wc -l < "$STATE_DIR/processed.log" | tr -d ' ')
        today_total=$(grep "^$(date -u '+%Y-%m-%d')" "$STATE_DIR/processed.log" 2>/dev/null | wc -l | tr -d ' ')
        echo "Processed:  $total total, $today_total today"
    fi

    if [ -f "$STATE_DIR/events.log" ]; then
        local cycles errors
        cycles=$(grep -c 'CYCLE_DONE' "$STATE_DIR/events.log" 2>/dev/null || echo 0)
        errors=$(grep -c 'ERROR\|FAILED\|TIMEOUT' "$STATE_DIR/events.log" 2>/dev/null || echo 0)
        echo "Cycles:     $cycles completed"
        echo "Errors:     $errors total"
    fi

    echo ""

    # Locks
    local has_locks=false
    for lockfile in "$LOCK_DIR"/*.lock; do
        [ -e "$lockfile" ] || continue
        local lock_name lock_time now age
        lock_name=$(basename "$lockfile" .lock)
        lock_time=$(cat "$lockfile" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$(( now - lock_time ))
        echo "⚠️  Lock: $lock_name (held ${age}s)"
        has_locks=true
    done
    if [ "$has_locks" = false ]; then
        echo "Locks:      none (clean)"
    fi

    echo ""
    echo "Last 5 events:"
    if [ -f "$STATE_DIR/events.log" ]; then
        tail -5 "$STATE_DIR/events.log" | while IFS='|' read -r ts agent event msg; do
            printf "  %-20s %-10s %-15s %s\n" "$ts" "$agent" "$event" "$msg"
        done
    fi
}

# ────────────────────────────────────────────
# START / STOP / RESTART
# ────────────────────────────────────────────
do_start() {
    if [ ! -f "$PLIST_PATH" ]; then
        echo "Not installed. Run ./install.sh first."
        exit 1
    fi
    echo "▶️  Starting..."
    launchctl load "$PLIST_PATH" 2>/dev/null || true
    launchctl start "$SERVICE_LABEL"
    sleep 2
    do_status
}

do_stop() {
    echo "⏹️  Stopping..."
    launchctl stop "$SERVICE_LABEL" 2>/dev/null || true
    # Clean stale locks (per-project + global pool)
    rm -f "$LOCK_DIR"/*.lock 2>/dev/null || true
    rm -f "$GLOBAL_LOCK_DIR"/claude-*.lock 2>/dev/null || true
    rm -rf "$GLOBAL_LOCK_DIR"/claude-*.d 2>/dev/null || true
    sleep 2
    echo "Stopped."
}

do_restart() {
    do_stop
    sleep 2
    do_start
}

# ────────────────────────────────────────────
# LOGS
# ────────────────────────────────────────────
do_logs() {
    mkdir -p "$LOG_DIR"
    for f in orchestrator cto senior-engineer reviewer launchd-stdout launchd-stderr; do
        touch "$LOG_DIR/$f.log"
    done
    echo "Tailing all logs (Ctrl+C to stop)..."
    echo ""
    tail -f "$LOG_DIR"/*.log
}

do_errors() {
    if [ -f "$STATE_DIR/events.log" ]; then
        echo "Errors and failures:"
        grep -E 'ERROR|FAILED|TIMEOUT|RATE_LIMITED|LOCK_TIMEOUT' "$STATE_DIR/events.log" | tail -30
    else
        echo "No events yet."
    fi
}

# ────────────────────────────────────────────
# FORUM
# ────────────────────────────────────────────
do_forum() {
    local url="https://github.com/$GITHUB_REPO_FULL/discussions"
    echo "🌐 $url"
    open "$url" 2>/dev/null || xdg-open "$url" 2>/dev/null || echo "Open manually: $url"
}

# ────────────────────────────────────────────
# KICK (pass-through)
# ────────────────────────────────────────────
do_kick() {
    shift  # remove "kick" from args
    bash "$SCRIPT_DIR/kick.sh" "$@"
}

# ────────────────────────────────────────────
# UNINSTALL
# ────────────────────────────────────────────
do_uninstall() {
    echo "🗑️  Uninstalling..."
    launchctl stop "$SERVICE_LABEL" 2>/dev/null || true
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    rm -f "$SCRIPT_DIR/launchd-wrapper.sh"
    rm -f "$LOCK_DIR"/*.lock 2>/dev/null || true
    echo "✅ Service removed. Logs and state preserved in $SCRIPT_DIR."
}

# ────────────────────────────────────────────
case "${1:-help}" in
    status)    do_status ;;
    start)     do_start ;;
    stop)      do_stop ;;
    restart)   do_restart ;;
    logs)      do_logs ;;
    errors)    do_errors ;;
    forum)     do_forum ;;
    kick)      do_kick "$@" ;;
    uninstall) do_uninstall ;;
    help|*)
        echo "🏭 ctl.sh — Agent Factory control"
        echo ""
        echo "  ./ctl.sh status      Running? PID, cycles, errors"
        echo "  ./ctl.sh start       Start the service"
        echo "  ./ctl.sh stop        Stop + clear locks"
        echo "  ./ctl.sh restart     Restart"
        echo "  ./ctl.sh logs        Tail all logs"
        echo "  ./ctl.sh errors      Show error events"
        echo "  ./ctl.sh forum       Open GitHub Discussions"
        echo "  ./ctl.sh kick <cmd>  Run kick.sh (e.g. ctl.sh kick seed \"fix bug\")"
        echo "  ./ctl.sh uninstall   Remove launchd service"
        ;;
esac
