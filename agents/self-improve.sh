#!/bin/bash
# ============================================================
# 🧬 Self-Improvement Agent — Project-specific learning
#
# Makes the system smarter for THIS specific project by:
# 1. Reading past solutions (docs/solutions/) and review patterns
# 2. Extracting recurring rules → projects/<name>/rules.md
# 3. Extracting coding style → projects/<name>/style.md
# 4. Proposing CLAUDE.md updates for the target project
#
# This is what separates compound engineering from regular CI.
# Without this, the system repeats the same mistakes forever.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-learn}"
AGENT="self-improve"

log() { echo "[$(date '+%H:%M:%S')] [LEARN] $*"; }

# ────────────────────────────────────────────
# learn — Extract rules and style from accumulated knowledge
# ────────────────────────────────────────────
run_learn() {
    log "🧬 Learning from project history..."

    cd "$TARGET_PROJECT"

    # Count inputs
    local solution_count=0 todo_count=0
    [ -d "docs/solutions" ] && solution_count=$(ls docs/solutions/*.md 2>/dev/null | wc -l | tr -d ' ')
    [ -d "todos" ] && todo_count=$(ls todos/*.md 2>/dev/null | wc -l | tr -d ' ')

    if [ "$solution_count" -eq 0 ] && [ "$todo_count" -eq 0 ]; then
        log "  No solutions or todos yet — nothing to learn from"
        return 0
    fi

    log "  Solutions: $solution_count, Todos: $todo_count"

    # Tell Claude where to write the rules/style files
    local rules_path="${PROJECT_DIR:-$BASE_DIR}/rules.md"
    local style_path="${PROJECT_DIR:-$BASE_DIR}/style.md"

    local learn_prompt
    learn_prompt=$(load_prompt "self-improve-learn") || { log "Cannot load prompt"; return 1; }
    learn_prompt=$(render_prompt "$learn_prompt" \
        RULES_PATH "$rules_path" \
        STYLE_PATH "$style_path")

    local result
    result=$(safe_claude "$AGENT" "$learn_prompt" \
    --allowedTools "Bash,Read,Write,Edit,Glob,Grep") || {
        log "⚠️  Learning failed"
        return 1
    }

    # The prompt instructs Claude to write rules.md and style.md directly
    log "✅ Learning complete"

    # Check if CLAUDE.md updates were suggested
    if echo "$result" | grep -qi "CLAUDE.MD UPDATE"; then
        post_discussion "$CAT_ENGINEERING" "🧬 CLAUDE.md update suggested" \
"The self-improvement agent analyzed $solution_count solutions and $todo_count todos and suggests these updates to the project's CLAUDE.md:

$result

---
*Review and apply manually, or let the engineer apply next cycle.*" "$AGENT_SELF_IMPROVE" || true
    fi
}

case "$MODE" in
    learn) run_learn ;;
    *)     echo "Usage: $0 {learn}"; exit 1 ;;
esac
