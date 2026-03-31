#!/bin/bash
# ============================================================
# ♿ Accessibility Auditor Agent — WCAG compliance
#
# Scans UI code for accessibility violations:
# ARIA labels, color contrast, keyboard navigation,
# semantic HTML, screen reader compatibility.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-audit}"
AGENT="a11y-auditor"

log() { echo "[$(date '+%H:%M:%S')] [A11Y] $*"; }

run_audit() {
    log "♿ Auditing accessibility..."

    local prompt_text
    prompt_text=$(load_prompt "a11y-audit") || { log "Cannot load a11y-audit prompt"; return 1; }

    local result
    result=$(safe_claude "$AGENT" "$prompt_text" \
    --allowedTools "Read,Glob,Grep") || {
        log "⚠️  A11y audit failed"
        return 1
    }

    local result_len=${#result}
    if [ "$result_len" -lt 20 ]; then
        log "♿ No accessibility issues found"
        return 0
    fi

    # Parse and post issues
    echo "$result" | python3 -c "
import sys, json
text = sys.stdin.read()
try:
    start = text.index('[')
    end = text.rindex(']') + 1
    issues = json.loads(text[start:end])
    for issue in issues[:5]:
        print(json.dumps(issue))
except (ValueError, json.JSONDecodeError):
    pass
" 2>/dev/null | while IFS= read -r line; do
        [ -z "$line" ] && continue
        local title body
        title=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'[A11Y] {d[\"title\"]}')")
        body=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'**Priority:** {d[\"priority\"]}\n**Category:** accessibility\n**WCAG:** {d.get(\"wcag\",\"N/A\")}\n**Files:** {\", \".join(d.get(\"files\",[]))}\n\n{d[\"description\"]}\n\n**Fix:** {d[\"suggested_approach\"]}')")

        post_discussion "$CAT_TRIAGE" "$title" "$body" "$AGENT_A11Y" || continue
        log "📤 Posted: $title"
    done
}

case "$MODE" in
    audit) run_audit ;;
    *)     echo "Usage: $0 {audit}"; exit 1 ;;
esac
