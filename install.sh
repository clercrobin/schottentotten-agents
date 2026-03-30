#!/bin/bash
# ============================================================
# 🏭 install.sh — Install the Agent Factory as a launchd service
#
# This makes the factory a proper macOS daemon:
# - Starts on boot
# - Auto-restarts on crash
# - Logs to a known location
# - Managed with launchctl (like systemctl)
#
# Usage:
#   ./install.sh          Install + start the service
#   ./install.sh remove   Uninstall the service
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

SERVICE_LABEL="com.agentfactory.orchestrator"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"
WRAPPER="$SCRIPT_DIR/launchd-wrapper.sh"

do_install() {
    echo "🏭 Installing Agent Factory as launchd service..."
    echo ""

    # Pre-flight
    command -v gh >/dev/null 2>&1 || { echo "❌ gh CLI not found. brew install gh"; exit 1; }
    command -v claude >/dev/null 2>&1 || { echo "❌ claude CLI not found."; exit 1; }
    [ -d "$TARGET_PROJECT" ] || { echo "❌ Target project not found: $TARGET_PROJECT"; exit 1; }

    # Create the wrapper script that launchd will call
    cat > "$WRAPPER" << 'WRAPPER_EOF'
#!/bin/bash
# launchd wrapper — sets up env and runs the orchestrator
# NOTE: Do NOT source .zshrc — it can hang, exit, or break the daemon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export HOME="__HOME__"
export LANG="en_US.UTF-8"

# Hardcode PATH — covers Homebrew (ARM + Intel), local bins, system
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.claude/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Verify critical tools exist before starting
for cmd in gh claude git; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "FATAL: $cmd not found in PATH=$PATH" >&2
        exit 1
    }
done

source "$SCRIPT_DIR/config.sh"

exec "$SCRIPT_DIR/orchestrator.sh" --loop
WRAPPER_EOF

    # Replace placeholder with actual home dir
    sed -i '' "s|__HOME__|$HOME|g" "$WRAPPER"
    chmod +x "$WRAPPER"

    # Create the launchd plist
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST_PATH" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${WRAPPER}</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>

    <!-- Start on load (i.e. on login / boot) -->
    <key>RunAtLoad</key>
    <true/>

    <!-- Auto-restart on crash, with throttle -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <!-- Wait 30s before restarting after crash -->
    <key>ThrottleInterval</key>
    <integer>30</integer>

    <!-- Logs -->
    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/logs/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/logs/launchd-stderr.log</string>

    <!-- Environment -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:${HOME}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>LANG</key>
        <string>en_US.UTF-8</string>
    </dict>

    <!-- Resource limits -->
    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>4096</integer>
    </dict>

    <!-- Nice level — don't hog the CPU -->
    <key>Nice</key>
    <integer>10</integer>

    <!-- Process type — background, low priority -->
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST_EOF

    echo "✅ Plist written to: $PLIST_PATH"

    # Load the service
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"

    echo "✅ Service loaded and started."
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  Management commands:"
    echo ""
    echo "  ./ctl.sh status       Service status"
    echo "  ./ctl.sh stop         Stop the factory"
    echo "  ./ctl.sh start        Start the factory"
    echo "  ./ctl.sh restart      Restart"
    echo "  ./ctl.sh logs         Tail logs"
    echo "  ./ctl.sh forum        Open Discussions"
    echo "  ./ctl.sh uninstall    Remove the service"
    echo "═══════════════════════════════════════════"
}

do_remove() {
    echo "🗑️  Removing Agent Factory service..."
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    rm -f "$WRAPPER"
    echo "✅ Service removed."
}

case "${1:-install}" in
    install) do_install ;;
    remove)  do_remove ;;
    *)       echo "Usage: $0 [install|remove]" ;;
esac
