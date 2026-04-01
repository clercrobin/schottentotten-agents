#!/bin/bash
# ============================================================
# State management — tracks what's been processed
#
# macOS does NOT ship flock. We use mkdir for atomic locking
# (POSIX-guaranteed atomic on all filesystems).
# ============================================================

_STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# STATE_DIR may already be set by config-loader.sh for project isolation.
# Fall back to the default location next to the lib/ directory.
STATE_DIR="${STATE_DIR:-$_STATE_LIB_DIR/../state}"
mkdir -p "$STATE_DIR"

STATE_FILE="$STATE_DIR/processed.log"
STATE_LOCKDIR="$STATE_DIR/.state.lockdir"

# Per-project lock dir (for state file spinlock, etc.)
LOCK_DIR="$STATE_DIR/locks"
mkdir -p "$LOCK_DIR"

# Global lock dir for claude session pool — shared across ALL projects.
# Always lives at the base engine level so two projects can't exceed
# MAX_PARALLEL_SESSIONS by each maintaining their own independent pool.
_GLOBAL_BASE="${BASE_DIR:-$_STATE_LIB_DIR/..}"
GLOBAL_LOCK_DIR="$_GLOBAL_BASE/state/locks"
mkdir -p "$GLOBAL_LOCK_DIR"

# ────────────────────────────────────────────
# Internal: acquire/release a file-level spinlock via mkdir
# ────────────────────────────────────────────
_state_lock() {
    local attempts=0
    while ! mkdir "$STATE_LOCKDIR" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -gt 50 ]; then
            # Stale lock — force remove after 30s of waiting
            echo "[state] Forcing stale state lock" >&2
            rmdir "$STATE_LOCKDIR" 2>/dev/null || rm -rf "$STATE_LOCKDIR"
            mkdir "$STATE_LOCKDIR" 2>/dev/null || return 1
            return 0
        fi
        sleep 0.1 2>/dev/null || sleep 1
    done
}

_state_unlock() {
    rmdir "$STATE_LOCKDIR" 2>/dev/null || true
}

# ────────────────────────────────────────────
# Mark a discussion as processed by an agent
# Usage: mark_processed <discussion_number> <agent> <action>
# ────────────────────────────────────────────
mark_processed() {
    local disc_num="$1"
    local agent="$2"
    local action="$3"
    _state_lock
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')|${disc_num}|${agent}|${action}" >> "$STATE_FILE"
    _state_unlock
}

# ────────────────────────────────────────────
# Check if a discussion was already processed
# Returns 0 if already processed, 1 if not
# ────────────────────────────────────────────
is_processed() {
    local disc_num="$1"
    local agent="$2"
    local action="$3"
    # Read is safe without lock (append-only file, grep is atomic enough)
    grep -q "|${disc_num}|${agent}|${action}$" "$STATE_FILE" 2>/dev/null
}

# ────────────────────────────────────────────
# Acquire a named lock (for claude session, etc.)
# Uses mkdir for atomic test-and-set
# ────────────────────────────────────────────
acquire_lock() {
    local lock_name="$1"
    local stale_after="${2:-900}"
    local lock_file="$LOCK_DIR/${lock_name}.lock"
    local lock_dir="$LOCK_DIR/${lock_name}.d"

    # Check for stale lock
    if [ -f "$lock_file" ]; then
        local lock_time now age
        lock_time=$(cat "$lock_file" 2>/dev/null || echo "0")
        now=$(date +%s)
        age=$(( now - lock_time ))

        if [ "$age" -gt "$stale_after" ]; then
            echo "[state] Removing stale lock '$lock_name' (${age}s old)" >&2
            rm -f "$lock_file"
            rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir"
        else
            return 1
        fi
    fi

    # Atomic acquire
    if mkdir "$lock_dir" 2>/dev/null; then
        date +%s > "$lock_file"
        return 0
    else
        return 1
    fi
}

# ────────────────────────────────────────────
# Release a lock
# ────────────────────────────────────────────
release_lock() {
    local lock_name="$1"
    rm -f "$LOCK_DIR/${lock_name}.lock"
    rmdir "$LOCK_DIR/${lock_name}.d" 2>/dev/null || rm -rf "$LOCK_DIR/${lock_name}.d"
}

# ────────────────────────────────────────────
# Acquire a slot from the GLOBAL claude session pool
# Usage: acquire_pool_slot "claude" 3 [stale_after]
# Returns slot number (0-based) on stdout, or fails
#
# Uses GLOBAL_LOCK_DIR so the pool is shared across all projects.
# ────────────────────────────────────────────
acquire_pool_slot() {
    local pool_name="$1"
    local pool_size="$2"
    local stale_after="${3:-900}"

    local i=0
    while [ "$i" -lt "$pool_size" ]; do
        local lock_file="$GLOBAL_LOCK_DIR/${pool_name}-${i}.lock"
        local lock_dir="$GLOBAL_LOCK_DIR/${pool_name}-${i}.d"

        # Check for stale lock
        if [ -f "$lock_file" ]; then
            local lock_time now age
            lock_time=$(cat "$lock_file" 2>/dev/null || echo "0")
            now=$(date +%s)
            age=$(( now - lock_time ))
            if [ "$age" -gt "$stale_after" ]; then
                echo "[state] Removing stale pool lock '${pool_name}-${i}' (${age}s old)" >&2
                rm -f "$lock_file"
                rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir"
            else
                i=$((i + 1))
                continue
            fi
        fi

        # Atomic acquire
        if mkdir "$lock_dir" 2>/dev/null; then
            date +%s > "$lock_file"
            echo "$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# ────────────────────────────────────────────
# Release a specific pool slot (global)
# Usage: release_pool_slot "claude" 2
# ────────────────────────────────────────────
release_pool_slot() {
    local pool_name="$1"
    local slot="$2"
    rm -f "$GLOBAL_LOCK_DIR/${pool_name}-${slot}.lock"
    rmdir "$GLOBAL_LOCK_DIR/${pool_name}-${slot}.d" 2>/dev/null || rm -rf "$GLOBAL_LOCK_DIR/${pool_name}-${slot}.d"
}

# ────────────────────────────────────────────
# Log a structured event
# ────────────────────────────────────────────
log_event() {
    local agent="$1"
    local event_type="$2"
    local message="$3"
    _state_lock
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')|${agent}|${event_type}|${message}" >> "$STATE_DIR/events.log"
    _state_unlock
}

# ────────────────────────────────────────────
# Get count of items processed today
# ────────────────────────────────────────────
today_count() {
    local agent="$1"
    local today
    today=$(date -u '+%Y-%m-%d')
    grep "^${today}.*|${agent}|" "$STATE_FILE" 2>/dev/null | wc -l | tr -d ' '
}

# ────────────────────────────────────────────
# Rotate state files (call periodically)
# ────────────────────────────────────────────
rotate_state() {
    local max_bytes="${1:-5242880}"

    for f in "$STATE_FILE" "$STATE_DIR/events.log"; do
        if [ -f "$f" ]; then
            local size
            size=$(wc -c < "$f" | tr -d ' ')
            if [ "$size" -gt "$max_bytes" ]; then
                _state_lock
                local archive="${f}.$(date '+%Y%m%d%H%M%S').bak"
                cp "$f" "$archive"
                tail -1000 "$f" > "${f}.tmp"
                mv "${f}.tmp" "$f"
                _state_unlock
                echo "[state] Rotated $(basename "$f")" >&2
            fi
        fi
    done
}
